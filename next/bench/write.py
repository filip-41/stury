"""write.py: the write lanes of next/ against the other libraries' writers, GB/s as the best round of each arm's median.

Usage: python3 next/bench/write.py [--rounds N] [LANE...]
Lanes: `typed` (a struct value to compact text), `typed_pretty`, `doc` (a parsed document to compact text) and
`doc_pretty`. A typed lane counts the output's bytes and a document lane the source's. Every lane runs on the
fixtures in `FIXTURES`. The arms are yy (yyjson), simd (simdjson), sonic (sonic-rs), serde (serde_json) and
next, each present when its binary is under next/build/bench. `ARMS=yy,sonic` keeps a subset.

An arm that has no writer for a lane is left out of it: simdjson has no pretty writer and no typed writer, and its
`simd_min` arm is `simdjson::minify` of the source text, which writes no document and is not checked against the
others. The arms that write the same job must write the same text, so their `check=` values must agree before a
fixture is timed, except on the fixtures in `SPELLING`, where the libraries spell the same values differently.

next's arm is the probe `next/build/bench/write`, which `make bench-write` builds from `next/bench/write/` when that
directory exists. Its command line is `write MODE FILE [pretty]` with MODE `typed` or `doc`, and it prints one line
of `gb_per_s=`, `ns=`, `out=` and `check=` as the other arms do. `check` is FNV-1a over the output text.
"""
import fcntl, os, sys

from doc import BUILD, LOCK, path as fixture, run

NEXT = os.path.join(BUILD, "write")
YY = os.path.join(BUILD, "yy_bench")
SIMD = os.path.join(BUILD, "cpp_bench")
RUST = os.path.join(BUILD, "rust", "release", "write")

TYPED_FIXTURES = ["logs.json", "twitter.json", "citm_catalog.json", "canada.json", "nested.json", "wide.json"]
DOC_FIXTURES = ["logs.json", "twitter.json", "citm_catalog.json", "canada.json", "pretty.json", "utf8.json",
                "escape.json", "longtext.json"]
FIXTURES = {"typed": TYPED_FIXTURES, "typed_pretty": TYPED_FIXTURES, "doc": DOC_FIXTURES, "doc_pretty": DOC_FIXTURES}
# nested.json has small doubles, which yyjson spells `e-05` and serde_json and sonic-rs `e-5`. escape.json has
# strings that each library re-escapes its own way, and integers past 64 bits that each handles its own way.
SPELLING = {"nested.json", "escape.json"}
# next writes a whole float with no fraction, as jq does, and the other libraries write `1.0`, on a struct's floats. A
# document keeps the source's spelling, and sonic-rs and serde_json respell a float of their DOM.
WHOLE_FLOATS = {"logs.json", "canada.json"}
ARMS = ["next", "yy", "simd", "simd_min", "sonic", "serde"]
UNCHECKED = {"simd_min"}


def command(arm, mode, pretty, path):
    """The arm's command line for the lane, or None where the arm has no writer for it."""
    tail = ["pretty"] if pretty else []
    if arm == "next":
        return [NEXT, mode, path, *tail]
    if arm == "yy":
        return [YY, "write_typed" if mode == "typed" else "write_doc", path, *tail]
    if arm in ("sonic", "serde"):
        return [RUST, arm, mode, path, *tail]
    if arm in ("simd", "simd_min") and mode == "doc" and not pretty:
        return [SIMD, path, "simd_doc_write" if arm == "simd" else "simd_minify"]
    return None


def present(arm):
    binary = {"next": NEXT, "yy": YY, "simd": SIMD, "simd_min": SIMD, "sonic": RUST, "serde": RUST}[arm]
    return os.path.exists(binary)


def race(lane, name, arms, rounds):
    mode, pretty = lane.split("_")[0], lane.endswith("_pretty")
    path = fixture(name)
    cmds = {a: command(a, mode, pretty, path) for a in arms}
    cmds = {a: c for a, c in cmds.items() if c}
    best = dict.fromkeys(cmds, 0.0)
    checks = {}
    for r in range(rounds):
        for arm, cmdline in cmds.items():
            gb, checks[arm], _ = run(cmdline)
            best[arm] = max(best[arm], gb)
        compared = {a: c for a, c in checks.items() if a not in UNCHECKED}
        spelled = name in SPELLING or name in WHOLE_FLOATS
        if r == 0 and len(set(compared.values())) > 1 and not spelled:
            sys.exit(f"texts disagree on {lane} {name}: {compared}")
    return best


def main(argv):
    rounds = int(os.environ.get("ROUNDS") or 5)
    if argv[:1] == ["--rounds"]:
        rounds = int(argv[1])
        argv = argv[2:]
    lanes = [lane for arg in argv for lane in arg.split(",")] or list(FIXTURES)
    wanted = os.environ["ARMS"].split(",") if os.environ.get("ARMS") else ARMS
    have = [a for a in ARMS if a in wanted and present(a)]
    if not have:
        sys.exit("no write arm is built: run make bench-write")
    print("arms: " + " ".join(have) + ("; left out: " + " ".join(a for a in ARMS if a not in have) if len(have) < len(ARMS) else ""))
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        for lane in lanes:
            print(f"\n{lane} GB/s")
            print(f"{'file':20}" + "".join(f"{a:>10}" for a in have))
            for name in FIXTURES[lane]:
                best = race(lane, name, have, rounds)
                print(f"{name:20}" + "".join(f"{best[a]:10.3f}" if a in best else f"{'-':>10}" for a in have), flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
