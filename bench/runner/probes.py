import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from typing import NamedTuple

from . import guard
from .layout import BENCH, BUILD, FIXTURES

LANES = BENCH / "lanes"
ODIN_FLAGS = ["-o:speed"]
CARGO = {"": BUILD / "cargo", "schema": BUILD / "cargo-schema"}


def lane_toml(lane):
    with open(LANES / lane / "lane.toml", "rb") as f:
        return tomllib.load(f)


def binary(lane, source):
    """The program a lane's arm runs, from the arm's `source` (a directory of Odin, a C or C++ file, or `rust`)."""
    if source == "rust":
        target = CARGO["schema" if lane == "schema" else ""]
        return target / "release" / f"{lane}-rust"
    return BUILD / f"{lane}-{source.partition('.')[0]}"


def fixture(name):
    """The path of a fixture by name, looking in fixtures/ and then fixtures/corpus/, else NAME as a path."""
    for d in (FIXTURES, FIXTURES / "corpus"):
        if (d / name).exists():
            return str(d / name)
    if os.path.exists(name):
        return os.path.abspath(name)
    sys.exit(f"no fixture {name}: looked in bench/fixtures and bench/fixtures/corpus. `bench fixtures` fetches the corpus "
             "and generates the rest")


def run_build(cmd, what, cwd=None, env=None):
    """Runs a build command, printing nothing on success and its output on failure. Returns whether it passed."""
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env={**os.environ, **(env or {})})
    if p.returncode:
        print(f"{what}: build failed\n{p.stdout}{p.stderr}", file=sys.stderr)
    return p.returncode == 0


def build(lanes):
    """Builds the programs the arms of LANES run: the Odin probe of each, then the C and C++ drivers, then the Rust ones.
    A toolchain that is not on PATH leaves its arms out with a note. Returns whether everything built passed."""
    sources = {(lane, arm["source"]) for lane in lanes for arm in lane_toml(lane)["arm"].values()}
    ok = True
    odin = os.environ.get("ODIN", "odin")
    BUILD.mkdir(parents=True, exist_ok=True)
    for lane, source in sorted(sources):
        if source == "stury":
            flags = ODIN_FLAGS + [f"-define:TIER={os.environ.get('TIER', '0')}"] * (lane == "kernel")
            ok &= run_build([odin, "build", f"bench/lanes/{lane}/stury", *flags, f"-out:{binary(lane, source)}"],
                            f"{lane}-stury", cwd=BENCH.parent)
    native = sorted((lane, s) for lane, s in sources if s.endswith((".c", ".cc", ".cpp")))
    if native and shutil.which("cmake"):
        ok &= run_build(["cmake", "-S", BENCH, "-B", BUILD / "cmake", f"-DBENCH_OUT={BUILD}"], "cmake")
        targets = [f"{lane}-{s.partition('.')[0]}" for lane, s in native]
        ok &= run_build(["cmake", "--build", BUILD / "cmake", "--target", *targets, "-j", str(os.cpu_count())], "cmake")
    elif native:
        print("C and C++ drivers: left out (cmake is not on PATH)")
    for schema, flag in ((False, ""), (True, "schema")):
        packages = sorted(f"{lane}-rust" for lane, s in sources if s == "rust" and (lane == "schema") == schema)
        if not packages:
            continue
        if not shutil.which("cargo"):
            print("Rust drivers: left out (cargo is not on PATH)")
            continue
        manifest = ["--manifest-path", str(LANES / "schema" / "rust" / "Cargo.toml")] if schema else \
            [f"--package={p}" for p in packages]
        ok &= run_build(["cargo", "build", "--release", "--locked", *manifest], "cargo", cwd=BENCH,
                        env={"CARGO_TARGET_DIR": str(CARGO[flag])})
    return ok


class Measure(NamedTuple):
    gb_per_s: float
    check: int
    ns: int
    peak_mib: float


def parse(out):
    """The key=value tokens of a probe's output line as a dict of strings."""
    return dict(re.findall(r"(\w+)=(\S+)", out))


def measure(cmd, env=None, timeout=None):
    """One run of a probe or driver: its gb_per_s, check, ns and peak RSS in MiB. Raises guard.Failed when it fails or
    prints no gb_per_s or check."""
    r = guard.run(cmd, env, timeout)
    found = parse(r.out)
    if "gb_per_s" not in found or "check" not in found:
        raise guard.Failed(f"no gb_per_s or check: {r.out.strip()[:80]}")
    return Measure(float(found["gb_per_s"]), int(found["check"]), int(found.get("ns", 0)), r.peak_mib)
