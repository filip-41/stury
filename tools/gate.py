#!/usr/bin/env python3
"""Runs the checks a change can reach, and skips those that passed on the same inputs.

A check's key hashes what can change its answer: the compiler, the check's command, the `STURY_` variables, which loosen
or skip cases of the suites, and every file its packages import for its target, the compiler's own `base` and `core`
packages among them, with comments dropped, plus what they `#load`. A key that passed is stamped under the git common
directory, so all worktrees of the repository share the stamps and a merge reruns nothing its branch ran.

Run from the repository root: `python3 tools/gate.py [quick|merge|full]`, `--force` to ignore stamps, `--list` to print what would run,
`-j N` for the compiles at once. `quick` is the edit loop, `merge` what a branch passes before it lands (`make gate`), and
`full` adds the long randomized runs. A check that cannot run on this machine is named in the last lines, not passed.
"""

import argparse
import concurrent.futures
import dataclasses
import functools
import hashlib
import os
import re
import platform
import shutil
import subprocess
import sys
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


@dataclasses.dataclass
class Check:
    name: str
    stage: int  # A stage runs once every earlier one passed, cheapest first.
    tier: int
    roots: list  # Package directories, whose imports are followed.
    cmd: list
    cwd: str = ROOT
    arch: str = HOST
    trees: list = dataclasses.field(default_factory=list)  # Whole directories, hashed as they are.
    also: str = ""  # A second architecture whose sources the check compiles.
    cli: bool = False  # Runs build/stury, which must be the binary the current sources make.


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
    """The command line's suites against jq: every jq and cli.tsv case passes, the smoke cases fail only where
    smoke.floor names them, the random cases of regex_diff and jq_diff hold none different, and the types and gen laws hold. They run on the binary `build-cli` makes,
    after every other stage so that a loaded host does not time them out."""
    test = at(f"{CLI}/test")
    suite = lambda name, stage, *argv, tier=1: Check(name, stage, tier, [at(CLI)], ["python3", *argv], trees=[test], cli=True)
    out = [
        suite("cli jq suite", 5, f"{test}/jq_suite.py", CLI_BINARY),
        suite("cli smoke", 5, f"{test}/smoke.py", CLI_BINARY),
        suite("cli types law", 5, f"{test}/types_law.py", CLI_BINARY),
        suite("cli gen law", 5, f"{test}/gen_law.py", CLI_BINARY, f"--odin={odin}"),
    ]
    has_jq = shutil.which("jq") and subprocess.run(["jq", "--version"], capture_output=True, text=True).stdout.strip() == "jq-1.8.2"
    # The merge tier runs the first seed, the full tier every seed.
    for i, seed in enumerate(DIFF_SEEDS):
        tier = 1 if i == 0 else 2
        out.append(suite(f"cli regex diff seed {seed}", 6, f"{test}/regex_diff.py", CLI_BINARY, f"--seed={seed}", tier=tier))
        if has_jq:
            out.append(suite(f"cli jq diff seed {seed}", 6, f"{test}/jq_diff.py", CLI_BINARY, f"--seed={seed}", tier=tier))
    if not has_jq:
        absent.append("cli jq diff (no jq 1.8.2 on PATH)")
    return out


def checks(odin):
    """Every check, cheapest stage first, and the groups left out because their checkout is absent. Each package is its
    own check, so a diff reruns only what imports it."""
    out = []
    absent = []
    examples = sorted(entry.path for entry in os.scandir(at("examples")) if entry.is_dir())
    # `checks.py imports` reads every tracked source, the examples' among them.
    every = [at(p) for p in LIB_PKGS + TEST_PKGS + BENCH_PKGS + [CLI]] + examples
    out.append(Check("lint", 0, 0, every, make(odin, "lint"), trees=[at("tools/checks.py"), at("API.txt"), at("API_SHARED.txt")], also="amd64"))
    out.append(Check("examples", 2, 1, examples, make(odin, "test-examples"), trees=[at("examples")]))
    if os.path.isdir(at(CLI)):
        # Only the merge tier's suites run the binary, and its -o:speed compile is the edit loop's longest step.
        out.append(Check("cli build", 1, 1, [at(CLI)], make(odin, "build-cli")))
        # The pieces law and the memory test build their own binaries, so they wait for the merge tier.
        for name, script, tier in (("cli pieces law", "pieces_law.py", 1), ("cli follow", "follow_test.py", 0), ("cli memory", "memory_test.py", 1)):
            script = at(f"{CLI}/test/{script}")
            out.append(Check(name, 2, tier, [at(CLI)], ["python3", script, f"--odin={odin}"], trees=[script, at(f"{CLI}/test/harness.py")]))
        out += cli_suites(absent, odin)
    for package in TEST_PKGS:
        name = package.replace("/", "-")
        root = [at(package)]
        golden = [at("json/test/golden")] if package == "json/test" else []
        out.append(Check(f"{name} minimal", 1, 0, root, make(odin, f"build/test/minimal/{package}"), trees=golden))
        out.append(Check(f"{name} speed", 2, 1, root, make(odin, f"build/test/speed/{package}"), trees=golden))
        out.append(Check(f"{name} asan", 3, 1, root, make(odin, f"build/test/asan/{package}"), trees=golden))
        if package in TSAN_PKGS:
            out.append(Check(f"{name} tsan", 3, 1, root, make(odin, f"build/test/tsan/{package}")))
        # The merge tier runs v2 at -o:none and v3 at -o:speed, the full tier the other two.
        for opt in ("none", "speed"):
            for tier in (0, 1) if rosetta() else ():
                target = f"build/test/x86/{opt}/{tier}/{package}"
                gate = 1 if (opt == "none") == (tier == 0) else 2
                out.append(Check(f"{name} x86 v{tier + 2} {opt}", 3, gate, root, make(odin, target), arch="amd64", trees=golden))
    if not rosetta():
        absent.append("the x86 test packages (no Rosetta, and this is not an x86-64 machine)")
    # Alone in the last stage, since it fills every core.
    out.append(Check("json-test full sweeps", 4, 2, [at("json/test")], make(odin, "test-sweep")))
    out.append(Check("f32 exhaustive", 4, 2, [at("core/spell"), at("core/spell/test")], make(odin, "test-f32")))
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


def run_check(check):
    start = time.monotonic()
    done = subprocess.run(check.cmd, cwd=check.cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    return check, done.returncode, done.stdout, time.monotonic() - start


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
    todo = {}
    skipped = 0
    for check in wanted:
        key = key_of(check, compiler)
        if not args.force and os.path.exists(os.path.join(stamps, key)):
            skipped += 1
        else:
            todo.setdefault(check.stage, []).append((check, key))
    if args.list:
        for stage in sorted(todo):
            for check, _ in todo[stage]:
                print(f"{stage} {check.name}")
        print(f"{sum(map(len, todo.values()))} to run, {skipped} unchanged")
        return 0

    builder = next((c for c in every if c.name == "cli build"), None)
    cli_key = builder and key_of(builder, compiler)
    ran = 0
    for stage in sorted(todo):
        keys = {check.name: key for check, key in todo[stage]}
        if any(check.cli for check, _ in todo[stage]) and not cli_current(cli_key):
            _, code, output, seconds = run_check(builder)
            print(f"{'ok  ' if code == 0 else 'FAIL'} {builder.name}, for the suites ({seconds:.1f}s)", flush=True)
            if code != 0:
                print(output[-6000:])
                return 1
            note_cli(cli_key)
        print(f"stage {stage}: {len(todo[stage])} checks", flush=True)
        failed = False
        pool = concurrent.futures.ThreadPoolExecutor(args.j)
        # map yields in the order of the checks, each as soon as it and those before it are done.
        for check, code, output, seconds in pool.map(run_check, [check for check, _ in todo[stage]]):
            ran += 1
            print(f"{'ok  ' if code == 0 else 'FAIL'} {check.name} ({seconds:.1f}s)", flush=True)
            if code == 0:
                with open(os.path.join(stamps, keys[check.name]), "w") as stamp:
                    stamp.write(check.name + "\n")
                if check is builder:
                    note_cli(cli_key)
            else:
                failed = True
                print(output[-6000:], flush=True)
        pool.shutdown()
        if failed:
            print(f"failed after {ran} checks, {skipped} unchanged, {time.monotonic() - start:.1f}s")
            print(*notice, sep="\n")
            return 1
    print(f"passed: {ran} ran, {skipped} unchanged, {time.monotonic() - start:.1f}s")
    print(*notice, sep="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
