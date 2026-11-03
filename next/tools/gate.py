#!/usr/bin/env python3
"""Runs the checks a change can reach, and skips those that passed on the same inputs.

A check's key hashes what can change its answer: the compiler, the check's command, and every file its packages import
for its target, with comments dropped, plus what they `#load`. A key that passed is stamped under the git common
directory, so all worktrees of the repository share the stamps and a merge reruns nothing its branch ran.

Run from next/: `python3 tools/gate.py [quick|merge|full]`, `--force` to ignore stamps, `--list` to print what would run,
`-j N` for the compiles at once. `quick` is the edit loop, `merge` what a branch passes before it lands, and `full` adds
the long randomized runs and fresh seeds with `--seed`.
"""

import argparse
import concurrent.futures
import dataclasses
import hashlib
import os
import re
import platform
import subprocess
import sys
import time

from checks import makefile_list

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(ROOT)
PRIVATE = os.path.join(os.path.dirname(REPO), "stury-tests", "next")
DEFAULT_ODIN = os.path.join(os.path.dirname(REPO), "Odin-master", "bin", "odin")

TIERS = {"quick": 0, "merge": 1, "full": 2}
HOST = "arm64"

# The Makefile keeps the package lists.
TEST_PKGS = makefile_list("TEST_PKGS")
TSAN_PKGS = makefile_list("TSAN_PKGS")
LIB_PKGS = makefile_list("LIB_PKGS") + makefile_list("SUPPORT_PKGS")
CLI = "cmd/stury"
BENCH_PKGS = ["bench", "bench/doc", "bench/editbench", "bench/paths", "bench/typed", "bench/write", "bench/records"]

IMPORT = re.compile(r'^\s*import\s+(?:[A-Za-z_]\w*\s+)?"([^"]+)"', re.MULTILINE)
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


def resolve_import(path, directory):
    """The directory an import names, or None for the compiler's own collections, which its identity covers."""
    if path.startswith(("core:", "base:", "vendor:")):
        return None
    if path.startswith("next:"):
        return os.path.join(ROOT, path[5:])
    if path.startswith("stury:"):
        return os.path.join(REPO, path[6:])
    return os.path.normpath(os.path.join(directory, path))


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
        digest.update(os.path.relpath(name, REPO).encode())
        with open(name, "rb") as file:
            digest.update(file.read())


def hash_closure(digest, roots, arch):
    """Adds every source of `roots` and what they import for `arch`, and what those sources load."""
    seen = set()
    todo = [os.path.normpath(root) for root in roots]
    loads = set()
    while todo:
        directory = todo.pop()
        if directory in seen or not os.path.isdir(directory):
            continue
        seen.add(directory)
        for name in sorted(os.listdir(directory)):
            if not name.endswith(".odin"):
                continue
            path = os.path.join(directory, name)
            with open(path, encoding="utf-8") as file:
                text = file.read()
            if not builds_for(text, arch):
                continue
            digest.update(os.path.relpath(path, REPO).encode())
            digest.update(strip_comments(text).encode())
            for imported in IMPORT.findall(text):
                target = resolve_import(imported, directory)
                if target:
                    todo.append(target)
            for loaded in LOAD.findall(text):
                loads.add(os.path.normpath(os.path.join(directory, loaded)))
    for path in sorted(loads):
        hash_tree(digest, path)


def compiler_id(odin):
    stat = os.stat(odin)
    return f"{stat.st_size}:{int(stat.st_mtime)}"


def key_of(check, odin_id):
    digest = hashlib.sha256()
    digest.update(odin_id.encode())
    digest.update(check.name.encode())
    digest.update(repr(check.cmd).encode())
    hash_tree(digest, os.path.join(check.cwd, "Makefile"))
    hash_closure(digest, check.roots, check.arch)
    if check.also:
        hash_closure(digest, check.roots, check.also)
    for tree in check.trees:
        hash_tree(digest, tree)
    return digest.hexdigest()


def stamp_directory():
    common = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.strip()
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


def checks(odin, seed):
    """Every check, cheapest stage first, and the groups left out because their checkout is absent. Each package is its
    own check, so a diff reruns only what imports it."""
    out = []
    absent = []
    every = [at(p) for p in LIB_PKGS + TEST_PKGS + BENCH_PKGS + [CLI]]
    out.append(Check("lint", 0, 0, every, make(odin, "lint"), trees=[at("tools/checks.py"), at("API.txt")], also="amd64"))
    out.append(Check("size", 0, 0, [at(p) for p in LIB_PKGS + [CLI]], ["python3", "tools/checks.py", "size"], trees=[at("tools/checks.py")]))
    if os.path.isdir(at(CLI)):
        out.append(Check("cli build", 1, 0, [at(CLI)], make(odin, "build-cli")))
    for package in TEST_PKGS:
        name = package.replace("/", "-")
        root = [at(package)]
        golden = [at("json/test/golden")] if package == "json/test" else []
        out.append(Check(f"{name} minimal", 1, 0, root, make(odin, f"build/test/minimal/{package}"), trees=golden))
        out.append(Check(f"{name} speed", 2, 1, root, make(odin, f"build/test/speed/{package}"), trees=golden))
        out.append(Check(f"{name} asan", 3, 1, root, make(odin, f"build/test/asan/{package}"), trees=golden))
        if package in TSAN_PKGS:
            out.append(Check(f"{name} tsan", 3, 1, root, make(odin, f"build/test/tsan/{package}")))
        for opt in ("none", "speed") if rosetta() else ():
            for tier in (0, 1):
                target = f"build/test/x86/{opt}/{tier}/{package}"
                out.append(Check(f"{name} x86 v{tier + 2} {opt}", 3, 1, root, make(odin, target), arch="amd64", trees=golden))
    # Alone in the last stage, since it fills every core.
    out.append(Check("f32 exhaustive", 4, 2, [at("core/spell"), at("core/spell/test")], make(odin, "test-f32")))
    if os.path.isdir(PRIVATE):
        private = [
            ("model/json", True), ("model/dsv", True), ("laws/json", False), ("laws/dsv", False), ("perf", False),
        ]
        for suite, randomized in private:
            binary = f"{ROOT}/build/test/private-{suite.replace('/', '-')}"
            flags = ["-o:speed", "-collection:stury=.", f"-collection:next={ROOT}", f"-out:{binary}"]
            if randomized:
                flags += [f"-define:SEED={seed}", "-define:ROUNDS=10000"]
            path = os.path.join(PRIVATE, suite)
            out.append(Check(f"private {suite}", 2, 1, [path], [odin, "test", path] + flags, cwd=REPO))
    else:
        absent.append(f"private suites ({PRIVATE} is not there)")
    compare = os.path.join(REPO, "compare")
    if not (os.path.isdir(compare) and os.path.isdir(os.path.join(REPO, "csv"))):
        absent.append(f"compare oracles and golden ({compare} or the old tree they read is not there)")
        return out, absent
    in_compare = lambda *names: [os.path.join(compare, name) for name in names]
    typed = in_compare("typed_oracle")
    out.append(Check(
        "compare lint", 0, 1, in_compare("json_oracle", "dsv_oracle", "golden", "found_probe", "marshal_oracle", "dsv_marshal_oracle", "document_oracle", "write_probe") + [at("json"), at("dsv")],
        make(odin, "lint"), cwd=compare, trees=typed,
    ))
    for tier, rounds, typed_rounds in ((1, 20000, 2000), (2, 100000, 20000)):
        label = "" if tier == 1 else " deep"
        for oracle in ("json_oracle", "dsv_oracle"):
            out.append(Check(
                f"{oracle}{label}", 3, tier, in_compare(oracle),
                make(odin, "test-oracle", ORACLES=oracle, ROUNDS=rounds, SEED=seed), cwd=compare,
            ))
        out.append(Check(
            f"typed oracle{label}", 3, tier, [at("json"), at("dsv"), os.path.join(REPO, "json"), os.path.join(REPO, "csv")],
            make(odin, "test-typed-oracle", ROUNDS=typed_rounds, SEED=seed), cwd=compare, trees=typed,
        ))
    out.append(Check(
        "marshal oracle", 3, 1, [at("json"), at("core/write"), at("core/typed"), os.path.join(REPO, "json")],
        make(odin, "test-marshal-oracle"), cwd=compare, trees=in_compare("marshal_oracle"),
    ))
    out.append(Check(
        "dsv marshal oracle", 3, 1, [at("dsv"), at("core/write"), at("core/typed"), os.path.join(REPO, "csv")],
        make(odin, "test-dsv-marshal-oracle"), cwd=compare, trees=in_compare("dsv_marshal_oracle"),
    ))
    out.append(Check(
        "document oracle", 3, 1, [at("json"), at("core/write"), os.path.join(REPO, "json")],
        make(odin, "test-document-oracle"), cwd=compare, trees=in_compare("document_oracle"),
    ))
    out.append(Check(
        "golden", 3, 1, in_compare("golden"),
        ["sh", "-c", f"make -s ODIN={odin} golden && git diff --exit-code -- ../next/json/test/golden"], cwd=compare,
    ))
    return out, absent


def run_check(check):
    start = time.monotonic()
    done = subprocess.run(check.cmd, cwd=check.cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    return check, done.returncode, done.stdout, time.monotonic() - start


def main():
    parser = argparse.ArgumentParser(description="Runs the checks a change can reach.")
    parser.add_argument("tier", nargs="?", default="quick", choices=TIERS)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("-j", type=int, default=4)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--odin", default=os.environ.get("ODIN", DEFAULT_ODIN))
    args = parser.parse_args()

    stamps = stamp_directory()
    os.makedirs(os.path.join(ROOT, "build", "test"), exist_ok=True)
    odin_id = compiler_id(args.odin)
    every, absent = checks(args.odin, args.seed)
    wanted = [c for c in every if c.tier <= TIERS[args.tier]]
    notice = [f"SKIPPED, not run and not passed: {what}" for what in absent]
    for line in notice:
        print(line, flush=True)
    start = time.monotonic()
    todo = {}
    skipped = 0
    for check in wanted:
        key = key_of(check, odin_id)
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

    ran = 0
    for stage in sorted(todo):
        keys = {check.name: key for check, key in todo[stage]}
        with concurrent.futures.ThreadPoolExecutor(args.j) as pool:
            results = list(pool.map(run_check, [check for check, _ in todo[stage]]))
        failed = False
        for check, code, output, seconds in results:
            ran += 1
            print(f"{'ok  ' if code == 0 else 'FAIL'} {check.name} ({seconds:.1f}s)", flush=True)
            if code == 0:
                with open(os.path.join(stamps, keys[check.name]), "w") as stamp:
                    stamp.write(check.name + "\n")
            else:
                failed = True
                print(output[-6000:])
        if failed:
            print(f"failed after {ran} checks, {skipped} unchanged, {time.monotonic() - start:.1f}s")
            print(*notice, sep="\n")
            return 1
    print(f"passed: {ran} ran, {skipped} unchanged, {time.monotonic() - start:.1f}s")
    print(*notice, sep="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
