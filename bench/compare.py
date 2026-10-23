#!/usr/bin/env python3
"""stury's read side against other libraries, job by job: typed decode, validate, DOM and GetOne.

Typed decode has two kinds of arm: generic decoders (stury's unmarshal, serde_json and sonic-rs derive) and
readers hand-written per shape on a parser API (simdjson On-Demand, yyjson's DOM), labelled `hand-written`.

Every arm is a process that times its job in process (2 warm-up calls, then the median of 10) and prints
key=value tokens; stury's arms are its bench lanes. This script runs every arm of a job RUNS times, interleaved
round by round with the arm order rotated, keeps the median, and prints one markdown table per input.

  check   before any timing: each typed arm's decoded value must equal stury's unmarshal (compared as JSON
          values), every arm is run over the strictness probes (faulty documents), printing who accepts what,
          and every GetOne arm must agree on whether the key is there and on the size of its value. Exits 1
          when a typed arm differs or fails, when stury itself gives a wrong strictness verdict, or when the
          GetOne arms disagree.
  time    the timings. --jobs picks among typed, validate, dom, getone; --out DIR writes DIR/results.json
          (every sample) and DIR/report.md (the tables under the run's commit, machine and library versions).
  cycles  for close calls: one iteration's retired instructions and cycles (`/usr/bin/time -l` on macOS, `perf
          stat` on Linux) on the same arm at 10 and at 50 timed iterations, differenced over 40, so loading and
          checking cancel.
          It counts what each iteration does outside the clock as well (an arena reset, a free, a drop).
          stury's 50-iteration build: build/probe50 (`compare.py build` builds both)

  build   compiles every arm into build/: stury's probes, then each other library whose sources or toolchain are
          here (bench/README.md says where they come from). A library that cannot be built is reported and
          left out of the tables, never dropped silently.

Usage (any working directory; inputs come from `python3 bench/gen.py` and `python3 bench/fetch.py`):
  python3 bench/compare.py build
  python3 bench/compare.py check
  python3 bench/compare.py time --runs 11 [--jobs typed,dom] [--out DIR]
  python3 bench/compare.py cycles --jobs dom --inputs nested.json,logs.json
"""
import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import tomllib

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BENCH)
BUILD = os.path.join(ROOT, "build", "bench")

FIX = os.path.join(BENCH, "fixtures")
MANIFEST = os.path.join(BENCH, "manifest.toml")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_measurement(text):
    """An arm's whitespace-separated `key=value` tokens, finite numeric values only."""
    vals = {}
    for tok in text.split():
        k, eq, v = tok.partition("=")
        if eq:
            try:
                x = float(v)
            except ValueError:
                continue
            if math.isfinite(x):
                vals[k] = x
    return vals


def run(cmd, env=None):
    """One process: (its tokens, None), or (None, why it failed: its last output line or its exit status)."""
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        last = (p.stderr or p.stdout).strip().splitlines()[-1:]
        return None, last[0] if last else "exit %d" % p.returncode
    return parse_measurement(p.stdout), None


def ns_of(tok, size):
    """One run's time in ns, or None when the arm printed no timing. The other libraries' arms print their exact `ns`
    (per call, for GetOne); stury's GetOne lane prints it for the arm `--emit` names, every other stury lane
    gb_per_s."""
    if tok.get("ns", 0) > 0:
        return tok["ns"]
    if tok.get("gb_per_s", 0) > 0:
        return size / tok["gb_per_s"]
    return None


_reported = set()


def built(arms):
    """ARMS without those whose binary is not built; each missing binary is reported once as left out."""
    for cmd in arms.values():
        if not os.path.exists(cmd[0]) and cmd[0] not in _reported:
            _reported.add(cmd[0])
            print("left out: %s, not built (python3 bench/compare.py build)" % os.path.relpath(cmd[0], ROOT), flush=True)
    return {a: cmd for a, cmd in arms.items() if os.path.exists(cmd[0])}


def measure(arms, runs, size):
    """Runs every arm RUNS times, round by round with the arm order rotated each round, so drift lands on every
    arm alike. An arm that fails, or prints no timing, is not run again. Returns ({arm: [ns, one per run]},
    {arm: why it failed})."""
    samples = {a: [] for a in arms}
    failed = {}
    names = list(arms)
    for r in range(runs):
        k = r % len(names)
        for a in names[k:] + names[:k]:
            if a in failed:
                continue
            tok, why = run(arms[a])
            if why is None and ns_of(tok, size) is None:
                why = "no ns or gb_per_s in its output"
            if why is not None:
                failed[a] = why
                continue
            samples[a].append(ns_of(tok, size))
    return samples, failed


def counters(cmd, env=None):
    """One run's retired instructions and cycles, or None when the command fails. `/usr/bin/time -l` on macOS,
    `perf stat` on Linux; anywhere else, or where the tool reports neither, a RuntimeError rather than a blank."""
    if sys.platform == "darwin":
        p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True, env=env)
        pat = r"^\s*(\d+)\s+(instructions) retired|^\s*(\d+)\s+(cycles) elapsed"
    elif sys.platform.startswith("linux") and shutil.which("perf"):
        p = subprocess.run(["perf", "stat", "-x", ",", "-e", "instructions,cycles", "--"] + cmd,
                           capture_output=True, text=True, env=env)
        pat = r"^(\d+),[^,]*,(instructions)\b|^(\d+),[^,]*,(cycles)\b"
    else:
        raise RuntimeError("counters need /usr/bin/time -l (macOS) or perf (Linux); neither is here")
    if p.returncode != 0:
        return None
    got = {}
    for m in re.finditer(pat, p.stderr, re.M):
        n, name = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
        got[name] = int(n)
    if len(got) != 2:
        raise RuntimeError("no instruction and cycle counts from %s:\n%s" % (cmd[0], p.stderr[-400:]))
    return got


def _out(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    except OSError:
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def _cpu():
    if sys.platform == "darwin":
        return _out(["sysctl", "-n", "machdep.cpu.brand_string"])
    for line in (_out(["lscpu"]) or "").splitlines():
        if line.startswith("Model name:"):
            return line.split(":", 1)[1].strip()
    return platform.processor() or None


def _rust_crates(names):
    """Locked versions from rust_bench's Cargo.lock."""
    try:
        with open(os.path.join(BENCH, "peers/rust/Cargo.lock"), "rb") as f:
            lock = tomllib.load(f)
    except OSError:
        return {}
    return {p["name"]: p["version"] for p in lock.get("package", []) if p["name"] in names}


def _yyjson_src_version(src):
    """The version in `src/yyjson.h`, for a yyjson built from source as bench/README.md says."""
    try:
        with open(os.path.join(src, "yyjson.h")) as f:
            m = re.search(r'#define YYJSON_VERSION_STRING\s+"([^"]+)"', f.read())
    except OSError:
        return None
    return m and m.group(1)


def fixture_hashes(fixtures):
    """({name: sha256 of the file on disk, None when it is absent}, the names whose hash is not the manifest's)."""
    with open(MANIFEST, "rb") as f:
        pinned = dict(tomllib.load(f)["fixtures"], **pinned_corpus())
    got = {n: sha256_of(fx(n)) if os.path.exists(fx(n)) else None for n in sorted(set(fixtures))}
    return got, [n for n, h in got.items() if h is None or h != pinned.get(n)]


def binary_hashes():
    """{arm binary: sha256 of the file, None when it is not built}, so a report names the exact binaries."""
    bins = {"probe": STURY, "probe50": os.path.join(ROOT, "build", "probe50"), "cpp_bench": CPP,
            "yy_bench": YY, "read": RUST}
    return {n: sha256_of(p) if os.path.exists(p) else None for n, p in bins.items()}


def metadata(fixtures=()):
    """Where a run came from: the commit (dirty when tracked files differ from it), the machine, the compilers,
    the other libraries' versions where the system says, and the hash of every fixture file the run read,
    with the names of those that are not the manifest's."""
    status = _out(["git", "status", "--porcelain", "--untracked-files=no"])
    # The versions bench/sources.toml pins, unless the library's source variable points elsewhere: then pkg-config
    # (and, for yyjson, its header) says, and a library neither knows has no version.
    pinned = source_versions()
    libs = {}
    for name, var in (("simdjson", "SIMDJSON_SRC"), ("yyjson", "YYJSON_SRC"), ("RapidJSON", "RAPIDJSON_INC")):
        libs[name] = _out(["pkg-config", "--modversion", name]) if os.environ.get(var) else pinned.get(name.lower())
    if os.environ.get("YYJSON_SRC"):
        libs["yyjson"] = _yyjson_src_version(os.environ["YYJSON_SRC"])
    libs.update(_rust_crates({"serde_json", "sonic-rs"}))
    hashes, off_manifest = fixture_hashes(fixtures)
    return {
        "commit": _out(["git", "rev-parse", "HEAD"]),
        "dirty": None if status is None else status != "",
        "cpu": _cpu(),
        "os": platform.platform(),
        "load1": round(os.getloadavg()[0], 2),
        "odin": _out(["odin", "version"]),
        "rustc": _out(["rustc", "--version"]),
        "cc": (_out(["cc", "--version"]) or "").split("\n")[0] or None,
        "libraries": libs,
        "binaries": binary_hashes(),
        "fixtures": hashes,
        "fixtures_off_manifest": ", ".join(off_manifest) or "none",
    }


LOAD_MAX = 2.0  # the quiet-box bound on the 1-minute load average


def quotable(meta):
    """'yes', or 'no: <reasons>' when the run cannot back a published figure."""
    why = []
    if meta.get("dirty") is not False:
        why.append("uncommitted changes")
    if meta.get("fixtures_off_manifest") != "none":
        why.append("fixtures differ from the manifest: %s" % meta.get("fixtures_off_manifest"))
    if not meta.get("checked"):
        why.append("check skipped")
    if meta.get("load1", LOAD_MAX + 1) > LOAD_MAX:
        why.append("1-minute load %s over %.1f" % (meta.get("load1"), LOAD_MAX))
    return "no: " + ", ".join(why) if why else "yes"


def write_report(out_dir, title, meta, results, body):
    """results.json (the metadata and every result) and report.md (the metadata as a header, then BODY)."""
    os.makedirs(out_dir, exist_ok=True)
    meta = dict(meta, quotable=quotable(meta))
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump({"metadata": meta, "results": results}, f, indent=1)
    head = ["# " + title, ""]
    for k, v in meta.items():
        if isinstance(v, dict):
            v = ", ".join("%s %s" % kv for kv in v.items()) or "none"
        head.append("- %s: %s" % (k, v))
    with open(os.path.join(out_dir, "report.md"), "w") as f:
        f.write("\n".join(head) + "\n\n" + body)


STURY = os.environ.get("STURY_PROBE") or os.path.join(ROOT, "build", "probe")
CPP = os.path.join(BUILD, "cpp_bench")
YY = os.path.join(BUILD, "yy_bench")
RUST = os.path.join(BUILD, "rust", "release", "read")


def stury(lane, fixture=None, *extra):
    return [STURY, "--lane", lane] + (["--fixture", fixture] if fixture else []) + list(extra)


def fx(name):
    return os.path.join(FIX, name)


# Typed decode: (shape, fixture, stury unmarshal lane, other stury lanes, the other libraries' arms).
TYPED = [
    ("logs", "logs.json", "unmarshal_logs", ["check_logs", "tape_unmarshal_logs"], True),
    ("logs_subset", "logs.json", "unmarshal_logs_subset", ["unmarshal_logs_subset_lazy", "tape_unmarshal_logs_subset"], True),
    ("nested", "nested.json", "unmarshal_nested", ["tape_unmarshal_nested"], False),
    ("config", "config.json", "unmarshal_config", ["unmarshal_config_lazy", "tape_unmarshal_config"], True),
]


def typed_arms(shape, path, skips):
    arms = {
        "serde_json derive": [RUST, "serde", "typed", shape, path],
        "sonic-rs derive": [RUST, "sonic", "typed", shape, path],
        "simdjson od, hand-written": [CPP, path, "typed", shape],
        "yyjson dom, hand-written": [YY, "typed", shape, path],
    }
    # The counterpart of stury's arena arm: the output containers keep their capacity across reads.
    arms["simdjson od, hand-written, reused containers"] = [CPP, path, "typed", shape, "reuse"]
    if skips:
        arms["simdjson od, hand-written, skips judged"] = [CPP, path, "typed", shape, "strict"]
    return arms


def stury_typed_arms(lane, extra):
    """stury's typed arms for one shape: the heap arm (head), the arena arm, then the other lanes. Only the
    heap arm allocates as the other libraries do (`malloc`, the previous value freed outside the clock); the tape
    lanes read into the arena."""
    arms = {"stury %s (heap)" % lane: stury(lane), "stury, arena reset": stury(lane + "_arena")}
    for l in extra:
        where = " (arena reset)" if l.startswith("tape_") else " (heap)" if l.startswith("unmarshal_") else ""
        arms["stury " + l + where] = stury(l)
    return arms


# Validate and DOM inputs. The synthetic fixtures gen.py writes, each with its stury validate and DOM lanes:
# shapes chosen to stress one thing each (numbers, escapes, long strings, UTF-8, depth, width).
SYNTHETIC = {
    "logs.json": ("substrate_logs", "query_dom_logs"),
    "nested.json": ("substrate", "query_dom"),
    "wide.json": ("substrate_wide", "query_dom_wide"),
    "escape.json": ("substrate_escape", "query_dom_escape"),
    "longtext.json": ("substrate_longtext", "query_dom_longtext"),
    "utf8.json": ("substrate_utf8", "query_dom_utf8"),
    "utf8_sparse.json": ("substrate_utf8_sparse", "query_dom_utf8_sparse"),
    "pretty.json": ("substrate_pretty", "query_dom_pretty"),
    "deep.json": ("substrate_deep", "query_dom_deep"),
}


def pins():
    with open(os.path.join(BENCH, "sources.toml"), "rb") as f:
        return tomllib.load(f)["pin"]


def pinned_corpus():
    """{fixture name under bench/fixtures: sha256} of the real-world documents bench/fetch.py downloads."""
    return {"corpus/" + p["name"]: p["sha256"] for p in pins() if p["kind"] == "corpus"}


def source_versions():
    """{library: version} of the other libraries' sources bench/fetch.py downloads."""
    return {p["name"]: p["version"] for p in pins() if p["kind"] == "source"}


def docs():
    """[(fixture, stury validate cmd, stury DOM cmd, stury DOM + read-every-value cmd)]: the synthetic fixtures,
    then the corpus."""
    out = [(f, stury(v), stury(d), stury("dom_read", fx(f))) for f, (v, d) in SYNTHETIC.items()]
    out += [(f, stury("substrate", fx(f)), stury("query_dom", fx(f)), stury("dom_read", fx(f)))
            for f in sorted(pinned_corpus())]
    return out


# (label, fixture, key, stury's lane). The config.json keys sit early, in the middle, late and nowhere in a
# synthetic root object; twitter.json's last root key is a real document's late key.
GETONE = [("early", "config.json", "k0000000", "path_ab_early"), ("middle", "config.json", "k0024000", "path_ab_middle"),
          ("late", "config.json", "k0048000", "path_ab_late"), ("absent", "config.json", "nope", "path_ab_absent"),
          ("search_metadata", "corpus/twitter.json", "search_metadata", "path_ab_late")]

# The guarantee each get-one arm gives. stury `.Strict` judges every byte of the input; simdjson On-Demand
# validates UTF-8 and indexes the structure of the whole input, but reads (and so judges) only the values it
# visits; `.Lazy` and sonic-rs stop at the match.
WHOLE, INDEXED, STOPS = "whole input judged", "whole input indexed, UTF-8 checked", "stops at the match"


def jobs():
    """Every timed table: (job, label, fixture, {arm: cmd}, stury's headline arm)."""
    out = []
    for shape, fixture, lane, extra, skips in TYPED:
        arms = stury_typed_arms(lane, extra)
        arms.update(typed_arms(shape, fx(fixture), skips))
        out.append(("typed", shape, fixture, arms, "stury %s (heap)" % lane))
    for fixture, vcmd, _, _ in docs():
        others = doc_arms(fx(fixture))
        arms = {"stury": vcmd, **{k: others[k] for k in ("simdjson od (every value read)", "simdjson dom")}}
        out.append(("validate", fixture, fixture, arms, "stury"))
    for fixture, _, dcmd, rcmd in docs():
        arms = {"stury .Dom build": dcmd, "stury DOM + read every value": rcmd, **doc_arms(fx(fixture))}
        del arms["simdjson od (every value read)"]
        out.append(("dom", fixture, fixture, arms, "stury .Dom build"))
    for where, fixture, key, lane in GETONE:
        # `--emit` names the arm of the A/B lane whose per-call time is this arm's `ns`.
        path = fx(fixture)
        stury_args = (path, "--key", key) if fixture != "config.json" else (None,)
        head = "stury .Strict (%s)" % WHOLE
        arms = {head: stury(lane, *stury_args, "--emit", "strict"),
                "stury .Lazy (%s)" % STOPS: stury(lane, *stury_args, "--emit", "lazy"),
                "simdjson od find_field (%s)" % INDEXED: [CPP, path, "get", key],
                "sonic-rs get (%s)" % STOPS: [RUST, "sonic", "get", path, key]}
        out.append(("getone", "%s %s" % (fixture, where), fixture, arms, head))
    return out


def time_jobs(selected, runs):
    """Every selected table's results, and the tables as markdown (printed as each one finishes)."""
    results, tables = [], []
    for job, inp, fixture, arms, head in jobs():
        if job not in selected:
            continue
        if not os.path.exists(fx(fixture)):
            print("left out: %s %s, no such file (bench/gen.py, bench/fetch.py)" % (job, fixture), flush=True)
            continue
        arms = built(arms)
        size = os.path.getsize(fx(fixture))
        t0 = time.time()
        samples, failed = measure(arms, runs, size)
        if head in failed:
            sys.exit("%s %s: stury's arm failed: %s" % (job, inp, failed[head]))
        med = {a: statistics.median(s) for a, s in samples.items() if s}
        results.append({"job": job, "input": inp, "bytes": size, "head": head, "samples": samples,
                        "median_ns": med, "failed": failed, "t0": t0, "t1": time.time()})
        tables.append(table(results[-1]))
        print(tables[-1], flush=True)
    return results, "\n".join(tables)


def table(r):
    head_ns = r["median_ns"].get(r["head"])
    per_call = r["job"] == "getone"  # a get-one answer's time is per call; GB/s of the whole file means nothing
    lines = ["", "### %s: %s (%d bytes)" % (r["job"], r["input"], r["bytes"]), "",
             "| arm | ns per call (median) | spread min–max ns | time ÷ head arm's |" if per_call else
             "| arm | GB/s (median) | spread min–max GB/s | time ÷ head arm's |", "|---|---:|---:|---:|"]
    for a, ns in sorted(r["median_ns"].items(), key=lambda kv: kv[1]):
        s = r["samples"][a]
        ratio = ("%.3g" if per_call else "%.2f") % (ns / head_ns) if head_ns else "–"
        if per_call:
            lines.append("| %s | %.0f | %.0f–%.0f | %s |" % (a, ns, min(s), max(s), ratio))
        else:
            lines.append("| %s | %.3f | %.3f–%.3f | %s |" % (a, r["bytes"] / ns, r["bytes"] / max(s), r["bytes"] / min(s), ratio))
    for a, why in r["failed"].items():
        lines.append("| %s | refused: %s | | |" % (a, why[:80]))
    return "\n".join(lines)


# ---- check ----

PROBE_REC = {"ts": "t", "level": "l", "service": "s", "msg": "m", "status": 200, "bytes": 1,
             "duration_ms": 1.5, "id": "x"}

# (name, member, raw value text): the member's value is replaced by the raw bytes. `status` and `id` are read
# by both shapes; `bytes` and `msg` only by `logs`, so for `logs_subset` they are skipped members.
FAULTS = [
    ("utf8_invalid", "S", b'"m\xff"'),
    ("ctrl_char", "S", b'"m\x01"'),
    ("bad_escape", "S", b'"m\\q"'),
    ("lone_surrogate", "S", b'"m\\ud800"'),
    ("leading_zero", "N", b"01"),
    ("bad_literal", "N", b"tru"),
    ("trailing_dot", "N", b"1."),
]


def probe_doc(member, raw):
    body = []
    for k, v in PROBE_REC.items():
        val = json.dumps(v).encode()
        if k == member:
            val = raw
        body.append(b'"' + k.encode() + b'":' + val)
    return b'{"logs":[{' + b",".join(body) + b"}]}"


def probes():
    """(name, bytes, expected): None = must refuse; a dict = must accept and read that record."""
    out = []
    for name, cls, raw in FAULTS:
        read, skipped = ("id", "msg") if cls == "S" else ("status", "bytes")
        out.append(("%s in a read member" % name, probe_doc(read, raw), None))
        out.append(("%s in a skipped member" % name, probe_doc(skipped, raw), None))
    base = probe_doc("x", b"")
    out.append(("trailing garbage", base + b" x", None))
    out.append(("duplicate status (last is 7)", base.replace(b'"status":200', b'"status":200,"status":7'),
                {"status": 7}))
    out.append(("escaped key st\\u0061tus", base.replace(b'"status"', b'"st\\u0061tus"'), {"status": 200}))
    out.append(("missing status", base.replace(b'"status":200,', b""), None))
    out.append(("status 200.0", base.replace(b'"status":200', b'"status":200.0'), None))
    out.append(("status 2e2", base.replace(b'"status":200', b'"status":2e2'), None))
    out.append(("status 2^63", base.replace(b'"status":200', b'"status":9223372036854775808'), None))
    return out


# Whole-document probes for the validate and DOM arms: (name, document, whether a strict reader accepts it).
DOC_PROBES = [
    ("clean", b'[{"a":"x","b":1.5,"c":[true,false,null]}]', True),
    ("invalid UTF-8", b'[{"a":"x\xff","b":1}]', False),
    ("control char", b'[{"a":"x\x01","b":1}]', False),
    ("bad escape", b'[{"a":"x\\q","b":1}]', False),
    ("lone surrogate \\ud800", b'[{"a":"x\\ud800","b":1}]', None),
    ("leading zero", b'[{"a":"x","b":01}]', False),
    ("bad literal", b'[{"a":"x","b":tru}]', False),
    ("trailing dot", b'[{"a":"x","b":1.}]', False),
    ("trailing garbage", b'[{"a":"x","b":1}] x', False),
    ("integer 2^64", b'[{"a":"x","b":18446744073709551616}]', True),
    ("1e400", b'[{"a":"x","b":1e400}]', None),
    ("depth 1025", b"[" * 1025 + b"]" * 1025, None),
]


def doc_arms(path):
    return {
        "simdjson od (every value read)": [CPP, path, "validate"],
        "yyjson": [YY, "dom", path], "sonic-rs": [RUST, "sonic", "dom", path], "simdjson dom": [CPP, path, "simd_dom"],
        "rapidjson": [CPP, path, "rapid_dom_warm"], "serde_json": [RUST, "serde", "dom", path],
    }


def run_dump(cmd, dump):
    env = dict(os.environ, STURY_DUMP=dump)
    if os.path.exists(dump):
        os.remove(dump)
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.returncode != 0 or not os.path.exists(dump):
        return None
    with open(dump, "rb") as f:
        return json.loads(f.read())


def getone_disagreement(arms):
    """None when the arms agree, else why not. Stury's lane reports how many answers it found, the other libraries
    the byte size of the value (0 when absent)."""
    present, sizes = {}, {}
    for a, cmd in built(arms).items():
        tok, why = run(cmd)
        if why is not None:
            return "%s failed: %s" % (a, why)
        stury_arm = cmd[0] == STURY
        n = tok.get("answers" if stury_arm else "answer_bytes")
        if n is None:
            return "%s printed no answer count" % a
        present[a] = n > 0
        if not stury_arm:
            sizes[a] = n
    if len(set(present.values())) > 1:
        return "presence differs: %s" % present
    if len(set(sizes.values())) > 1:
        return "answer sizes differ: %s" % sizes
    return None


def check():
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        dump = os.path.join(tmp, "dump.json")
        print("## Typed output against stury's unmarshal\n")
        for shape, fixture, lane, _, skips in TYPED:
            want = run_dump(stury(lane), dump)
            if want is None:
                print("%s: stury's lane failed" % shape)
                return 1
            every_arm = built({"stury, arena reset": stury(lane + "_arena"), **typed_arms(shape, fx(fixture), skips)})
            for arm, cmd in every_arm.items():
                got = run_dump(cmd, dump)
                verdict = "equal" if got == want else ("FAILED" if got is None else "DIFFERS")
                bad += verdict != "equal"
                print("- %s, %s: %s" % (shape, arm, verdict))

        print("\n## Strictness probes (one record; `ok` = the expected verdict)\n")
        arms_of = {}
        for shape in ("logs", "logs_subset"):
            arms_of[shape] = dict({"stury": None}, **built(typed_arms(shape, "PROBE", True)))
        names = list(arms_of["logs"])
        print("| probe | shape | " + " | ".join(names) + " |")
        print("|---|---|" + "---|" * len(names))
        for i, (name, doc, expect) in enumerate(probes()):
            path = os.path.join(tmp, "probe_%02d.json" % i)
            with open(path, "wb") as f:
                f.write(doc)
            for shape in ("logs", "logs_subset"):
                cells = []
                for arm in names:
                    cmd = arms_of[shape][arm]
                    cmd = stury("unmarshal_" + shape, path) if cmd is None else [path if c == "PROBE" else c for c in cmd]
                    got = run_dump(cmd, dump)
                    if expect is None:
                        hit = got is None
                        cells.append("refuses ok" if hit else "**accepts**")
                    elif got is None:
                        hit = False
                        cells.append("**refuses**")
                    else:
                        rec = got["logs"][0]
                        hit = all(rec.get(k) == v for k, v in expect.items())
                        cells.append("ok" if hit else "**reads %s**" % {k: rec.get(k) for k in expect})
                    bad += arm == "stury" and not hit
                print("| %s | %s | %s |" % (name, shape, " | ".join(cells)))
        print("\n## Whole-document probes (validate and DOM; `ok` = what RFC 8259 requires; a bare verdict = the RFC leaves it to the parser)\n")
        others = built(doc_arms("P"))
        names = ["stury validate", "stury DOM", "stury DOM + read every value"] + list(others)
        print("| probe | " + " | ".join(names) + " |")
        print("|---|" + "---|" * len(names))
        for name, doc, expect in DOC_PROBES:
            path = os.path.join(tmp, "probe_doc.json")
            with open(path, "wb") as f:
                f.write(doc)
            cmds = [stury("substrate", path), stury("query_dom", path), stury("dom_read", path)]
            cmds += [cmd for arm, cmd in doc_arms(path).items() if arm in others]
            cells = []
            for i, cmd in enumerate(cmds):
                ok = subprocess.run(cmd, capture_output=True).returncode == 0
                verdict = "accepts" if ok else "refuses"
                cells.append(verdict if expect is None else (verdict + " ok" if ok == expect else "**%s**" % verdict))
                bad += i < 3 and expect is not None and ok != expect  # the first three are stury's
            print("| %s | %s |" % (name, " | ".join(cells)))
    print("\n## GetOne (every arm agrees on whether the key is there and, among the other libraries, on its value's size)\n")
    for job, inp, _, arms, _ in jobs():
        if job == "getone":
            why = getone_disagreement(arms)
            bad += why is not None
            print("- %s: %s" % (inp, why or "agree"))
    return 1 if bad else 0


def cycles(selected, inputs, reps):
    stury50 = os.path.join(ROOT, "build", "probe50")
    for job, inp, fixture, arms, head in jobs():
        if job not in selected or (inputs and inp not in inputs):
            continue
        print("\n### %s: %s, per iteration (median of %d differences)\n" % (job, inp, reps))
        print("| arm | instructions | cycles | cycles ÷ stury's |")
        print("|---|---:|---:|---:|")
        rows = {}
        for a, cmd in built(arms).items():
            hi_cmd = [stury50] + cmd[1:] if cmd[0] == STURY else cmd
            ds = []
            for _ in range(reps):
                lo = counters(cmd, dict(os.environ, BENCH_RUNS="10"))
                hi = counters(hi_cmd, dict(os.environ, BENCH_RUNS="50"))
                if lo and hi:
                    ds.append({k: (hi[k] - lo[k]) / 40 for k in lo})
            if ds:
                rows[a] = {k: statistics.median(d[k] for d in ds) for k in ds[0]}
        for a, r in sorted(rows.items(), key=lambda kv: kv[1]["cycles"]):
            base = rows.get(head, {}).get("cycles")
            print("| %s | %.3g | %.3g | %s |" % (a, r["instructions"], r["cycles"], "%.2f" % (r["cycles"] / base) if base else "–"))
        sys.stdout.flush()


# ---- build ----

# Where each other library's sources are: an environment variable, else what bench/fetch.py put in build/bench/deps.
DEPS = os.path.join(BUILD, "deps")
SIMDJSON_SRC = os.environ.get("SIMDJSON_SRC") or os.path.join(DEPS, "simdjson")
RAPIDJSON_INC = os.environ.get("RAPIDJSON_INC") or os.path.join(DEPS, "rapidjson", "include")
YYJSON_SRC = os.environ.get("YYJSON_SRC") or os.path.join(DEPS, "yyjson")


def native_flags():
    """The C and C++ arms' tuning for this CPU. On x86 RapidJSON needs SSE4.2 named to use it."""
    if platform.machine().lower() in ("arm64", "aarch64"):
        return ["-mcpu=native"], []
    return ["-march=native"], ["-DRAPIDJSON_SSE42"]


def build():
    """Builds every arm it can; exits 1 when stury's probe does not build, and names every library left out."""
    os.makedirs(BUILD, exist_ok=True)
    tune, cpp_only = native_flags()
    steps = [
        ("stury probe", None, ["odin", "build", "bench/probe", "-collection:stury=.", "-o:speed", "-out:build/probe"]),
        ("stury probe50", None, ["odin", "build", "bench/probe", "-collection:stury=.", "-o:speed",
                                 "-define:TIMED_ITERS=50", "-out:build/probe50"]),
        # simdjson from its single-header amalgamation, with the same flags as the other C and C++ code.
        ("simdjson + RapidJSON", [os.path.join(SIMDJSON_SRC, "simdjson.cpp"), os.path.join(RAPIDJSON_INC, "rapidjson")],
         ["c++", "-std=c++20", "-O3", "-DNDEBUG", *tune, *cpp_only, "-Wno-deprecated-declarations",
          "-Wno-nontrivial-memcall", "-Wno-unknown-warning-option", "-I" + SIMDJSON_SRC, "-I" + RAPIDJSON_INC,
          "bench/peers/cpp_bench.cpp", os.path.join(SIMDJSON_SRC, "simdjson.cpp"), "-o", CPP]),
        # yyjson compiled with the arm, as its documentation suggests: a prebuilt shared yyjson cannot specialize
        # `yyjson_read_opts` for the flags and allocator it is called with.
        ("yyjson", [os.path.join(YYJSON_SRC, "yyjson.c")],
         ["cc", "-O3", "-DNDEBUG", "-flto", *tune, "-I" + YYJSON_SRC, "bench/peers/yy_bench.c",
          os.path.join(YYJSON_SRC, "yyjson.c"), "-o", YY]),
        ("serde_json + sonic-rs", None, ["cargo", "build", "--release", "--locked", "--quiet",
                                         "--target-dir", os.path.join(BUILD, "rust")]),
    ]
    left_out = []
    for name, needs, cmd in steps:
        missing = [n for n in needs or [] if not os.path.exists(n)] + ([] if shutil.which(cmd[0]) else [cmd[0]])
        if missing:
            left_out.append("%s: missing %s" % (name, ", ".join(missing)))
            continue
        print("== " + name, flush=True)
        # cargo reads .cargo/config.toml (target-cpu=native) from its working directory.
        cwd = os.path.join(BENCH, "peers", "rust") if cmd[0] == "cargo" else ROOT
        if subprocess.run(cmd, cwd=cwd).returncode != 0:
            if name.startswith("stury"):
                return 1
            left_out.append("%s: build failed" % name)
    for why in left_out:
        print("left out: " + why)
    return 0


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["build", "check", "time", "cycles"])
    ap.add_argument("--runs", type=int, default=11)
    ap.add_argument("--jobs", default="typed,validate,dom,getone")
    ap.add_argument("--out", help="time: the directory for results.json and report.md")
    ap.add_argument("--inputs", default="", help="cycles: the tables to count, by input label (comma-separated)")
    ap.add_argument("--reps", type=int, default=5, help="cycles: differences per arm")
    ap.add_argument("--skip-check", action="store_true", help="time: skip `check` (the run is not quotable)")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        return build()
    if not os.path.exists(STURY):
        sys.exit("no %s: python3 bench/compare.py build first" % STURY)
    if a.cmd == "check":
        return check()
    if a.cmd == "cycles":
        cycles(set(a.jobs.split(",")), set(filter(None, a.inputs.split(","))), a.reps)
        return 0
    selected = set(a.jobs.split(","))
    meta = dict(metadata(fx for job, _, fx, _, _ in jobs() if job in selected), runs=a.runs)
    print(meta)
    # Nothing is timed until every arm has shown it answers as stury does.
    if not a.skip_check and check() != 0:
        print("check failed: no timings (--skip-check times anyway, and the report says so)")
        return 1
    meta["checked"] = not a.skip_check
    res, body = time_jobs(selected, a.runs)
    if a.out:
        write_report(a.out, "stury against other JSON libraries", meta, res, body)
    return 0


if __name__ == "__main__":
    os.chdir(ROOT)  # the probe finds its fixtures from the stury checkout's root
    sys.exit(main(sys.argv[1:]))
