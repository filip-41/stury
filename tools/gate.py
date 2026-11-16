#!/usr/bin/env python3
"""Runs the checks a change can reach, and skips those that passed on the same inputs.

A check's key hashes what can change its answer: the compiler, the check's command, the `STURY_` variables, which loosen
or skip cases of the suites, and every file its packages import for its target, the compiler's own `base` and `core`
packages among them, with comments dropped, plus what they `#load`. A key that passed is stamped under the git common
directory, so all worktrees of the repository share the stamps and a merge reruns nothing its branch ran.

Run from the repository root: `python3 tools/gate.py [quick|merge|full]`, `--force` to ignore stamps, `--list` to print what would run,
`-j N` for the slots the checks share. `quick` is the edit loop, `merge` what a branch passes before it lands (`make gate`, and
the pre-push hook), and `full` adds the long randomized runs. A check that cannot run on this machine is named in the last
lines, not passed.

Every check that is due starts as soon as a slot is free, the longest expected chain first, by the seconds each took when
it last passed. Only the command line's suites wait, for the binary. The first failure stops every running check.
"""

import argparse
import dataclasses
import functools
import hashlib
import json
import os
import queue
import re
import platform
import shutil
import signal
import subprocess
import sys
import threading
import time

from checks import makefile_list, odin_problem

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TIERS = {"quick": 0, "merge": 1, "full": 2}
HOST = "amd64" if platform.machine() in ("x86_64", "AMD64") else "arm64"

# The Makefile keeps the package lists.
TEST_PKGS = makefile_list("TEST_PKGS")
TSAN_PKGS = makefile_list("TSAN_PKGS")
LIB_PKGS = makefile_list("LIB_PKGS") + makefile_list("SUPPORT_PKGS")
CLI = "cmd/stury"
CLI_BINARY = os.path.join(ROOT, "build", "stury")
CLI_RECORD = CLI_BINARY + ".key"
# The seeds of jq_diff and regex_diff, the ones CI and `make diff` run.
DIFF_SEEDS = makefile_list("DIFF_SEEDS")
BENCH_PKGS = makefile_list("BENCH_PKGS")

IMPORT = re.compile(r'^\s*(?:@\([^)]*\)\s*)?import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"', re.MULTILINE)
LOAD = re.compile(r'#load(?:_directory|_hash)?\(\s*"([^"]+)"')
BUILD_TAG = re.compile(r"^#\+build\s+(.+)$", re.MULTILINE)
# Strings come first, so a `//` inside one stays. A nested block comment ends early, which keeps text and only costs a
# rerun.
COMMENT = re.compile(
    r'(?P<keep>"(?:\\.|[^"\\\n])*"|`[^`]*`|\'(?:\\.|[^\'\\\n])*\')|//[^\n]*|/\*.*?\*/', re.DOTALL
)
ARCHES = {"amd64", "arm64", "riscv64", "i386", "arm32", "wasm32", "wasm64p32"}
# A check never timed runs first, as if it were the longest.
UNTIMED_SECONDS = 1e6
# The slots of a check that fills every core, which runs alone.
EVERY_SLOT = 1 << 10


@dataclasses.dataclass
class Check:
    name: str
    tier: int
    roots: list  # Package directories, whose imports are followed.
    cmd: list
    cwd: str = ROOT
    arch: str = HOST
    trees: list = dataclasses.field(default_factory=list)  # Whole directories, hashed as they are.
    also: str = ""  # A second architecture whose sources the check compiles.
    cli: bool = False  # Runs build/stury, which must be the binary the current sources make.
    slots: int = 1  # The -j slots its own threads fill.


def strip_comments(text):
    """`text` without comments and blank lines, so an edit of comments alone keeps the key."""
    kept = COMMENT.sub(lambda m: m.group("keep") or "", text)
    return "\n".join(line.rstrip() for line in kept.splitlines() if line.strip())


def builds_for(text, arch):
    """Whether a file's `#+build` lines admit `arch`. A line's comma-separated terms are alternatives, a term's spaced
    tags must all hold, and a tag that names no architecture is taken to hold."""
    for line in BUILD_TAG.findall(text):
        admitted = False
        for term in line.split(","):
            holds = True
            for tag in term.split():
                negated = tag.startswith("!")
                name = tag.lstrip("!")
                if name in ARCHES and (name == arch) == negated:
                    holds = False
            admitted = admitted or holds
        if not admitted:
            return False
    return True


@dataclasses.dataclass(frozen=True)
class Compiler:
    identity: str
    root: str  # Holds the `base`, `core` and `vendor` collections.


def resolve_import(path, directory, compiler):
    """The directory an import names."""
    collection, _, rest = path.partition(":")
    if collection in ("core", "base", "vendor") and rest:
        return os.path.join(compiler.root, collection, rest)
    if collection == "stury" and rest:
        return os.path.join(ROOT, rest)
    return os.path.normpath(os.path.join(directory, path))


def source_name(path, compiler):
    """A source's name in a key, the same in every worktree."""
    if os.path.commonpath([compiler.root, path]) == compiler.root:
        return "odin:" + os.path.relpath(path, compiler.root)
    return os.path.relpath(path, ROOT)


def hash_tree(digest, path):
    """Adds a file or every file under a directory, bytes as they are."""
    if os.path.isfile(path):
        names = [path]
    else:
        names = []
        for base, dirs, files in os.walk(path):
            dirs[:] = sorted(d for d in dirs if d not in ("build", "__pycache__"))
            names += [os.path.join(base, name) for name in sorted(files) if name != ".DS_Store"]
    for name in names:
        digest.update(os.path.relpath(name, ROOT).encode())
        with open(name, "rb") as file:
            digest.update(file.read())


@functools.cache
def package_sources(directory, arch, compiler):
    """One package directory's sources that build for `arch`, comments dropped, with the directories they import and
    the paths they load."""
    text_of = []
    imports = []
    loads = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".odin"):
            continue
        path = os.path.join(directory, name)
        with open(path, encoding="utf-8") as file:
            text = file.read()
        if not builds_for(text, arch):
            continue
        text_of.append(source_name(path, compiler) + "\n" + strip_comments(text))
        imports += [resolve_import(imported, directory, compiler) for imported in IMPORT.findall(text)]
        loads += [os.path.normpath(os.path.join(directory, loaded)) for loaded in LOAD.findall(text)]
    return "\n".join(text_of).encode(), imports, loads


def hash_closure(digest, roots, arch, compiler):
    """Adds every source of `roots` and what they import for `arch`, the runtime every package imports, and what those
    sources load."""
    seen = set()
    todo = [os.path.normpath(root) for root in roots] + [os.path.join(compiler.root, "base", "runtime")]
    loads = set()
    while todo:
        directory = todo.pop()
        if directory in seen or not os.path.isdir(directory):
            continue
        seen.add(directory)
        text, imports, loaded = package_sources(directory, arch, compiler)
        digest.update(text)
        todo += imports
        loads.update(loaded)
    for path in sorted(loads):
        hash_tree(digest, path)


def compiler_of(odin):
    """The compiler `odin` runs: its root, the bytes of `odin` and of the root's own `odin`, which a wrapper script runs,
    and the version and backend it reports."""
    root = os.path.realpath(subprocess.run([odin, "root"], capture_output=True, text=True, check=True).stdout.strip())
    report = subprocess.run([odin, "report"], capture_output=True, text=True).stdout
    digest = hashlib.sha256(root.encode())
    digest.update("".join(re.findall(r"^\s*(?:Odin|Backend):.*$", report, re.MULTILINE)).encode())
    for program in sorted({os.path.realpath(shutil.which(odin) or odin), os.path.join(root, "odin")}):
        if os.path.isfile(program):
            with open(program, "rb") as file:
                digest.update(file.read())
    return Compiler(digest.hexdigest(), root)


def key_of(check, compiler):
    digest = hashlib.sha256()
    digest.update(compiler.identity.encode())
    digest.update(check.name.encode())
    digest.update(repr(check.cmd).encode())
    digest.update(repr(sorted((k, v) for k, v in os.environ.items() if k.startswith("STURY_"))).encode())
    hash_tree(digest, os.path.join(check.cwd, "Makefile"))
    hash_closure(digest, check.roots, check.arch, compiler)
    if check.also:
        hash_closure(digest, check.roots, check.also, compiler)
    for tree in check.trees:
        hash_tree(digest, tree)
    return digest.hexdigest()


def stamp_directory():
    """Under the git common directory, so worktrees share stamps, or build/ outside a git checkout."""
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        common = os.path.join(ROOT, "build")
    directory = os.path.join(common, "gate-stamps")
    os.makedirs(directory, exist_ok=True)
    return directory


def at(package):
    return os.path.join(ROOT, package)


def make(odin, target, **variables):
    return ["make", "-s", f"ODIN={odin}", target] + [f"{k}={v}" for k, v in variables.items()]


def rosetta():
    """Whether this machine runs x86-64 programs."""
    return platform.machine() == "x86_64" or os.path.exists("/Library/Apple/usr/libexec/oah/libRosettaRuntime")


def cli_suites(absent, odin):
    """The command line's suites against jq: every jq and cli.tsv case passes, every smoke case passes, every valid toml-test and yaml-test-suite case reads as its
    JSON says, the random cases of regex_diff and jq_diff hold none different, and the types and gen laws hold. They run on the binary `build-cli` makes,
    once that binary is built."""
    test = at(f"{CLI}/test")
    suite = lambda name, *argv, tier=1, slots=1: Check(name, tier, [at(CLI)], ["python3", *argv], trees=[test], cli=True, slots=slots)
    out = [
        suite("cli jq suite", f"{test}/jq_suite.py", CLI_BINARY),
        suite("cli smoke", f"{test}/smoke.py", CLI_BINARY),
        suite("cli conformance suite", f"{test}/conformance_suite.py", CLI_BINARY),
        suite("cli types law", f"{test}/types_law.py", CLI_BINARY),
        suite("cli gen law", f"{test}/gen_law.py", CLI_BINARY, f"--odin={odin}"),
        suite("cli follow", f"{test}/follow_test.py", CLI_BINARY),
        suite("cli memory", f"{test}/memory_test.py", CLI_BINARY),
    ]
    has_jq = shutil.which("jq") and subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip() == "jq-1.8.2"
    # The merge tier runs the first seed, the full tier every seed. Each runs its cases on every core.
    for i, seed in enumerate(DIFF_SEEDS):
        tier = 1 if i == 0 else 2
        out.append(suite(f"cli regex diff seed {seed}", f"{test}/regex_diff.py", CLI_BINARY, f"--seed={seed}", tier=tier, slots=3))
        if has_jq:
            out.append(suite(f"cli jq diff seed {seed}", f"{test}/jq_diff.py", CLI_BINARY, f"--seed={seed}", tier=tier, slots=3))
    if not has_jq:
        absent.append("cli jq diff (no jq 1.8.2 on PATH)")
    if subprocess.run(["python3", "-c", "import xml.parsers.expat"], capture_output=True).returncode == 0:
        out.append(Check("xml expat diff", 1, [at("xml"), at("xml/test/oracle")], make(odin, "diff-xml"), trees=[at("xml/test/oracle")]))
    else:
        absent.append("xml expat diff (no pyexpat in python3)")
    if shutil.which("uv"):
        script = at("core/model/test/pydantic_diff.py")
        out.append(Check("model pydantic diff", 2, [at("core/model"), at("core/model/test/oracle")], make(odin, "diff-model"), trees=[script]))
    else:
        absent.append("model pydantic diff (no uv)")
    return out


def checks(odin):
    """Every check, and the groups left out because their checkout is absent. Each package is its own check, so a diff
    reruns only what imports it."""
    out = []
    absent = []
    examples = sorted(entry.path for entry in os.scandir(at("examples")) if entry.is_dir())
    # `checks.py imports` reads every tracked source, the examples' among them.
    every = [at(p) for p in LIB_PKGS + TEST_PKGS + BENCH_PKGS + [CLI]] + examples
    out.append(Check("lint", 0, every, make(odin, "lint"), trees=[at("tools/checks.py"), at("API.txt"), at("API_SHARED.txt")], also="amd64", slots=2))
    if shutil.which("node"):
        out.append(Check("ecma node diff", 2, [at("core/regex"), at("core/regex/test/oracle")], make(odin, "ecma-diff"), trees=[at("core/regex/test/ecma_diff.py")]))
    else:
        absent.append("ecma node diff (no node on PATH)")
    out.append(Check("examples", 1, examples, make(odin, "test-examples"), trees=[at("examples")]))
    if os.path.isdir(at(CLI)):
        # Only the merge tier's suites run the binary, and its -o:speed compile is the edit loop's longest step.
        out.append(Check("cli build", 1, [at(CLI)], make(odin, "build-cli")))
        # The pieces law builds its own binaries, so it waits for the merge tier.
        script = at(f"{CLI}/test/pieces_law.py")
        out.append(Check("cli pieces law", 1, [at(CLI)], ["python3", script, f"--odin={odin}"], trees=[script, at(f"{CLI}/test/harness.py")]))
        out += cli_suites(absent, odin)
    for package in TEST_PKGS:
        name = package.replace("/", "-")
        root = [at(package)]
        golden = [at("json/test/golden")] if package == "json/test" else []
        out.append(Check(f"{name} minimal", 0, root, make(odin, f"build/test/minimal/{package}"), trees=golden))
        out.append(Check(f"{name} speed", 1, root, make(odin, f"build/test/speed/{package}"), trees=golden))
        out.append(Check(f"{name} asan", 1, root, make(odin, f"build/test/asan/{package}"), trees=golden))
        if package in TSAN_PKGS:
            out.append(Check(f"{name} tsan", 1, root, make(odin, f"build/test/tsan/{package}")))
        # The merge tier runs v2 at -o:none and v3 at -o:speed, the full tier the other two.
        for opt in ("none", "speed"):
            for tier in (0, 1) if rosetta() else ():
                target = f"build/test/x86/{opt}/{tier}/{package}"
                gate = 1 if (opt == "none") == (tier == 0) else 2
                out.append(Check(f"{name} x86 v{tier + 2} {opt}", gate, root, make(odin, target), arch="amd64", trees=golden))
    if not rosetta():
        absent.append("the x86 test packages (no Rosetta, and this is not an x86-64 machine)")
    # Alone, since each fills every core.
    out.append(Check("json-test full sweeps", 2, [at("json/test")], make(odin, "test-sweep"), slots=EVERY_SLOT))
    out.append(Check("f32 exhaustive", 2, [at("core/spell"), at("core/spell/test")], make(odin, "test-f32"), slots=EVERY_SLOT))
    return out, absent


def cli_record(key):
    """The key of the sources `build-cli` made build/stury from, with the binary's size and time, which any other build
    of it changes."""
    try:
        stat = os.stat(CLI_BINARY)
    except FileNotFoundError:
        return None
    return f"{key} {stat.st_size}:{stat.st_mtime_ns}"


def cli_current(key):
    try:
        with open(CLI_RECORD) as file:
            return file.read() == cli_record(key)
    except FileNotFoundError:
        return False


def note_cli(key):
    with open(CLI_RECORD, "w") as file:
        file.write(cli_record(key))


def load_seconds(stamps):
    """The seconds each check took when it last passed."""
    try:
        with open(os.path.join(stamps, "seconds.json")) as file:
            return json.load(file)
    except (FileNotFoundError, ValueError):
        return {}


def save_seconds(stamps, timed):
    """Adds `timed` to the stored seconds, which another worktree's gate may have written meanwhile."""
    stored = load_seconds(stamps)
    stored.update(timed)
    path = os.path.join(stamps, "seconds.json")
    with open(f"{path}.{os.getpid()}", "w") as file:
        json.dump(stored, file, indent=0, sort_keys=True)
    os.replace(f"{path}.{os.getpid()}", path)


def run_order(todo, builder, seconds):
    """`todo` by the longest expected chain first, the CLI build's chain holding the longest suite that waits for it."""
    expected = lambda check: seconds.get(check.name, UNTIMED_SECONDS)
    chain = {check.name: expected(check) for check in todo}
    if builder in todo:
        chain[builder.name] += max((expected(check) for check in todo if check.cli), default=0)
    return sorted(todo, key=lambda check: -chain[check.name])


def stop(proc):
    """Ends a check's command and everything it started, which share its process group."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass


def run_checks(ordered, builder, slots, passed):
    """Starts each check of `ordered` in turn once its slots are free, a CLI suite once `builder` has passed when it is
    due. A wider check that waits holds back those after it. `passed(check, seconds)` is called for each check that
    passes. The first failure stops every running check, and the result is whether none failed."""
    waiting = list(ordered)
    building = builder in waiting
    running = {}
    finished = queue.Queue()
    free = slots
    failed = False
    width = lambda check: min(check.slots, slots)
    try:
        while running or (waiting and not failed):
            for check in [] if failed else list(waiting):
                if check.cli and building:
                    continue
                if width(check) > free:
                    break
                waiting.remove(check)
                free -= width(check)
                proc = subprocess.Popen(check.cmd, cwd=check.cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
                running[proc] = (check, time.monotonic())
                threading.Thread(target=lambda proc=proc: finished.put((proc, proc.communicate()[0])), daemon=True).start()
            proc, output = finished.get()
            check, began = running.pop(proc)
            free += width(check)
            if failed:
                continue
            seconds = time.monotonic() - began
            if proc.returncode == 0:
                print(f"ok   {check.name} ({seconds:.1f}s)", flush=True)
                passed(check, seconds)
                building = building and check is not builder
            else:
                failed = True
                print(f"FAIL {check.name} ({seconds:.1f}s)", flush=True)
                print(output.decode(errors="replace")[-6000:], flush=True)
                for other in running:
                    stop(other)
    except KeyboardInterrupt:
        for proc in running:
            stop(proc)
        raise
    return not failed


def main():
    parser = argparse.ArgumentParser(description="Runs the checks a change can reach.")
    parser.add_argument("tier", nargs="?", default="quick", choices=TIERS)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("-j", type=int, default=8)
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    args = parser.parse_args()

    problem = odin_problem(args.odin)
    if problem:
        sys.exit(problem)
    # The makes the checks start need not ask the compiler again.
    os.environ["ODIN_CHECKED"] = "1"
    stamps = stamp_directory()
    os.makedirs(os.path.join(ROOT, "build", "test"), exist_ok=True)
    compiler = compiler_of(args.odin)
    every, absent = checks(args.odin)
    wanted = [c for c in every if c.tier <= TIERS[args.tier]]
    notice = [f"SKIPPED, not run and not passed: {what}" for what in absent]
    for line in notice:
        print(line, flush=True)
    start = time.monotonic()
    keys = {}
    for check in wanted:
        key = key_of(check, compiler)
        if args.force or not os.path.exists(os.path.join(stamps, key)):
            keys[check.name] = key
    todo = [check for check in wanted if check.name in keys]
    skipped = len(wanted) - len(todo)
    builder = next((c for c in every if c.name == "cli build"), None)
    cli_key = builder and key_of(builder, compiler)
    if any(check.cli for check in todo) and builder not in todo and not cli_current(cli_key):
        todo.append(builder)
        keys[builder.name] = cli_key
    seconds = load_seconds(stamps)
    ordered = run_order(todo, builder, seconds)
    if args.list:
        for check in ordered:
            print(f"{check.name} ({seconds[check.name]:.0f}s last)" if check.name in seconds else f"{check.name} (untimed)")
        print(f"{len(todo)} to run, {skipped} unchanged")
        return 0

    timed = {}

    def passed(check, took):
        with open(os.path.join(stamps, keys[check.name]), "w") as stamp:
            stamp.write(check.name + "\n")
        timed[check.name] = round(took, 1)
        if check is builder:
            note_cli(cli_key)

    print(f"{len(todo)} to run, {skipped} unchanged", flush=True)
    try:
        ok = run_checks(ordered, builder, args.j, passed)
    finally:
        save_seconds(stamps, timed)
    print(f"{'passed' if ok else 'failed'}: {len(timed)} ran, {skipped} unchanged, {time.monotonic() - start:.1f}s")
    print(*notice, sep="\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
