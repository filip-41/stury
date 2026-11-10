"""schema.py: the schema lane, stury beside Blaze, jsonschema-rs and boon on 19 schemas and their instances.

Usage: python3 bench/schema.py [--rounds N] [FIXTURE...]
`ARMS=stury,blaze` keeps a subset. Run it through `make bench-schema`.

Each fixture is a schema and a text of instances: a JSONL text, one instance per line, or one document. The job is
parse plus judge, every instance from its text to a verdict and dropped before the next, each arm with its own parser,
single thread, in two forms:
  verdict  Blaze's FastValidation, jsonschema's is_valid, boon's validate().is_ok().
  errors   every error: Blaze's SimpleOutput over an Exhaustive template, jsonschema's iter_errors, boon's basic output.
Each form prints three tables: GB/s of the instance text, µs per call (per instance), and instructions per call. GB/s
is the best round of each arm's median of ten calls after two warm-ups. Instructions per call are the difference
between two counted runs of different pass counts over the instance count, which cancels the setup; they come from
`/usr/bin/time -l` on macOS and `perf stat` on Linux.

The schema is the benchmark's `schema-noformat.json` (no `format` is asserted) for the 15 fixtures of
sourcemeta-research/jsonschema-benchmark, and a schema from bench/gen.py for logs, twitter, citm and applicator.

Until stury's schema check exists, the stury arm runs `json.validate` in both forms: it judges well-formedness, so its
`check` is left out of the agreement test and its columns are validate only. The arms that judge a schema must agree on
the verdict of every instance before a fixture is timed; one that disagrees or fails is left out of that fixture and named.
The runner holds build/bench/timing.lock and kills a child over 1 GiB of live RSS.
"""
import os, re, statistics, sys, tempfile

from guard import BUILD, count_prefix, counted, locked
from doc import FIX, HERE, Failed, parse_args, peak_mib, preamble, select_arms, spawn

BM = os.path.join(FIX, "jsonschema-benchmark")
GEN = os.path.join(FIX, "schema")
BIN = {
    "stury": os.path.join(BUILD, "schema_probe"),
    "blaze": os.path.join(BUILD, "blaze", "blaze_bench"),
    "jsonschema": os.path.join(BUILD, "rust-schema", "release", "schema"),
    "boon": os.path.join(BUILD, "rust-schema", "release", "schema"),
}
FORMS = ["verdict", "errors"]
TIMEOUT = 300
# A counted run makes this many passes more than the other, at least, and enough to read COUNT_BYTES of instances.
COUNT_PASSES = 3
COUNT_BYTES = 16 << 20

BENCHMARK = ["geojson", "openapi", "draft-04", "cmake-presets", "ui5-manifest", "helm-chart-lock", "cspell", "deno",
             "code-climate", "pulumi", "aws-cdk", "ansible-meta", "clang-format", "babelrc", "krakend"]
FIXTURES = {n: (f"{BM}/{n}/schema-noformat.json", f"{BM}/{n}/instances.jsonl") for n in BENCHMARK}
FIXTURES |= {n: (f"{GEN}/{n}.schema.json", f"{GEN}/{i}") for n, i in
             [("logs", "../logs.ndjson"), ("twitter", "twitter.json"), ("citm", "citm.json"), ("applicator", "applicator.ndjson")]}


def command(arm, form, schema, instances):
    tail = [form, schema, instances]
    if arm in ("jsonschema", "boon"):
        return [BIN[arm], arm, *tail]
    return [BIN[arm], *tail]


def timed(cmdline, verdicts=False):
    """(gb_per_s, ns, accepted, peak MiB, verdicts) of one run. The verdicts are the 0 and 1 of each instance, in order,
    when asked for, else None."""
    with tempfile.NamedTemporaryFile("r") as marks:
        out, _, usage = spawn(cmdline, {"BENCH_VERDICTS": marks.name} if verdicts else None, TIMEOUT)
        got = [re.search(rf"\b{k}=([\d.]+)", out) for k in ("gb_per_s", "ns", "check")]
        if not all(got):
            raise Failed("no gb_per_s, ns or check: " + out.strip()[:60])
        return (float(got[0].group(1)), int(got[1].group(1)), int(got[2].group(1)), peak_mib(usage.ru_maxrss),
                marks.read() if verdicts else None)


def instructions(cmdline, passes):
    """Instructions retired by one run of BENCH_PASSES=passes."""
    _, err, _ = spawn(count_prefix(["instructions"]) + cmdline, {"BENCH_PASSES": str(passes)}, TIMEOUT)
    n = counted(err, "instructions")
    if n is None:
        raise Failed("no instruction count")
    return n


def per_call(cmdline, size, calls):
    """Instructions per instance judged: two counted runs, COUNT_PASSES or more passes apart."""
    extra = max(COUNT_PASSES, min(200, COUNT_BYTES // size))
    return (instructions(cmdline, 1 + extra) - instructions(cmdline, 1)) / (extra * calls)


def first_difference(a, b):
    """The index of the first instance at which the verdict strings A and B differ."""
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))


def instance_count(path):
    if not path.endswith((".jsonl", ".ndjson")):
        return 1
    with open(path, "rb") as f:
        return sum(1 for line in f if line.strip())


def table(title, rows, arms, fmt, note=None):
    print(f"\n{title}")
    print(f"{'':16}" + "".join(f"{a:>12}" for a in arms))
    for name, cells in rows.items():
        print(f"{name:16}" + "".join(f"{fmt(cells[a]):>12}" if a in cells else f"{'-':>12}" for a in arms))
    if note:
        print(note)


def geomean_row(rows, arms, base="blaze"):
    """Each arm's geometric mean of its ratio to `base` over the rows where both ran."""
    out = []
    for a in arms:
        if a == "stury":
            out.append(f"{'-':>12}")
            continue
        r = [c[a] / c[base] for c in rows.values() if a in c and base in c and c[a] > 0 and c[base] > 0]
        out.append(f"{statistics.geometric_mean(r):12.2f}" if r else f"{'-':>12}")
    return f"{'geomean/' + base:16}" + "".join(out)


def judging(arms):
    return [a for a in arms if a != "stury"]


def lane(rounds, have, wanted):
    notes, verdicts = [], {}
    gbs, mics, inss = ({f: {} for f in FORMS} for _ in range(3))
    for name, (schema, instances) in FIXTURES.items():
        if wanted and name not in wanted:
            continue
        for p in (schema, instances):
            if not os.path.exists(p):
                sys.exit(f"no {os.path.relpath(p, os.path.dirname(HERE))}: run python3 bench/fetch.py corpus schema, then python3 bench/gen.py")
        size, calls = os.path.getsize(instances), instance_count(instances)
        for form in FORMS:
            live, accepted, marks = [], {}, {}
            for arm in have:
                try:
                    _, _, accepted[arm], _, marks[arm] = timed(command(arm, form, schema, instances), True)
                    live.append(arm)
                except Failed as e:
                    notes.append(f"{name} {form} {arm}: {e}")
            counts = [marks[a] for a in judging(live)]
            want = statistics.mode(counts) if counts else None
            for a in judging(live):
                if marks[a] != want:
                    notes.append(f"{name} {form} {a}: differs from the other arms at instance {first_difference(marks[a], want)}")
            if form == "verdict":
                verdicts[name] = (calls, accepted, {a: marks[a] == want for a in judging(live)})
            live = [a for a in live if a == "stury" or marks[a] == want]
            best = dict.fromkeys(live, 0.0)
            ns = dict.fromkeys(live, None)
            for _ in range(rounds):
                for arm in live:
                    try:
                        g, t, _, _, _ = timed(command(arm, form, schema, instances))
                    except Failed as e:
                        notes.append(f"{name} {form} {arm}: {e}")
                        continue
                    if g > best[arm]:
                        best[arm], ns[arm] = g, t
            gbs[form][name] = {a: b for a, b in best.items() if b > 0}
            mics[form][name] = {a: ns[a] / calls / 1000 for a in gbs[form][name]}
            row = {}
            for arm in live:
                try:
                    row[arm] = per_call(command(arm, form, schema, instances), size, calls)
                except Failed as e:
                    notes.append(f"{name} {form} {arm} instructions: {e}")
            inss[form][name] = row
        print(f"fixture {name}", flush=True)
    for form in FORMS:
        shown = [a for a in have if any(a in r for r in gbs[form].values())]
        table(f"{form}, parse + judge, GB/s of the instance text", gbs[form], shown, lambda v: f"{v:.3f}")
        print(geomean_row(gbs[form], shown))
        table(f"{form}, µs per call", mics[form], shown, lambda v: f"{v:.2f}")
        table(f"{form}, instructions per call", inss[form], shown, lambda v: f"{v:.0f}")
    shown = judging(have)
    print("\ninstances accepted in the verdict form, and whether every instance's verdict agrees\n" + f"{'':16}" + "".join(f"{a:>12}" for a in ["instances", *shown, "agree"]))
    for name, (calls, accepted, same) in verdicts.items():
        agree = len(same) == len(shown) and all(same.values())
        print(f"{name:16}{calls:>12}" + "".join(f"{accepted[a]:>12}" if a in accepted else f"{'-':>12}" for a in shown)
              + f"{'yes' if agree else 'NO':>12}")
    for n in notes:
        print("left out: " + n)


def main(argv):
    rounds, wanted = parse_args(argv, "python3 bench/schema.py [--rounds N] [FIXTURE...]")
    unknown = [w for w in wanted if w not in FIXTURES]
    if unknown:
        sys.exit(f"no fixture {' '.join(unknown)}: the fixtures are {' '.join(FIXTURES)}")
    have = select_arms(BIN, "bench-schema")
    if "stury" not in have:
        sys.exit("the stury arm is not running: run make bench-schema, and leave stury in ARMS")
    preamble(rounds, "Single thread, parse + judge per instance. GB/s: the best of {rounds} rounds of each arm's median of "
             "ten calls after two warm-ups. stury is json.validate only until its schema check lands.")
    print("load average at the start: %.1f %.1f %.1f on %d cores" % (*os.getloadavg(), os.cpu_count()))
    with locked():
        lane(rounds, have, wanted)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
