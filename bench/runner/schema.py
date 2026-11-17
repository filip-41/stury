import contextlib
import io
import os
import statistics
import sys
import tempfile

from . import fixtures as sources, guard, lane, probes
from .tables import machine, show

FORMS = ["verdict", "errors"]
TIMEOUT = 300
# A counted run makes this many passes more than the other, at least, and enough to read COUNT_BYTES of instances.
COUNT_PASSES = 3
COUNT_BYTES = 16 << 20


def spec():
    return probes.lane_toml("schema")


def fixtures():
    """Each fixture's name and its schema and instance paths."""
    return {r["label"]: (probes.fixture(r["schema"]), probes.fixture(r["file"])) for r in spec()["group"][0]["rows"]}


def built_arms(wanted=None):
    arms = spec()["arm"]
    return {n: a for n, a in arms.items() if (not wanted or n in wanted) and probes.binary("schema", a["source"]).exists()}


def command(arm, form, schema, instances):
    return lane.command("schema", spec()["arm"][arm], {"sub": form, "file": instances, "schema": schema})


def timed(cmd, verdicts=False):
    """(gb_per_s, ns, accepted, verdicts) of one run. The verdicts are the 0 and 1 of each instance, in order, when asked
    for, else None."""
    with tempfile.NamedTemporaryFile("r") as marks:
        r = guard.run(cmd, {"BENCH_VERDICTS": marks.name} if verdicts else None, TIMEOUT)
        m = probes.parse(r.out)
        if not all(k in m for k in ("gb_per_s", "ns", "check")):
            raise guard.Failed("no gb_per_s, ns or check: " + r.out.strip()[:60])
        return float(m["gb_per_s"]), int(m["ns"]), int(m["check"]), marks.read() if verdicts else None


def instructions(cmd, passes):
    return guard.counts(cmd, ["instructions"], {"BENCH_PASSES": str(passes)}, TIMEOUT)[0]


def per_call(cmd, size, calls):
    """Instructions per instance judged: two counted runs, COUNT_PASSES or more passes apart."""
    extra = max(COUNT_PASSES, min(200, COUNT_BYTES // size))
    return (instructions(cmd, 1 + extra) - instructions(cmd, 1)) / (extra * calls)


def first_difference(a, b):
    """The index of the first instance at which the verdict strings A and B differ."""
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))


def instance_count(path):
    if not path.endswith((".jsonl", ".ndjson")):
        return 1
    with open(path, "rb") as f:
        return sum(1 for line in f if line.strip())


def geomean_row(rows, arms, base="blaze"):
    """Each arm's geometric mean of its ratio to `base` over the rows where both ran."""
    out = []
    for a in arms:
        r = [c[a] / c[base] for c in rows.values() if a in c and base in c and c[a] > 0 and c[base] > 0]
        out.append(statistics.geometric_mean(r) if r else None)
    return ["geomean/" + base, *out]


def grid(title, rows, arms, fmt=None, extra=None):
    body = [[name, *[cells.get(a) for a in arms]] for name, cells in rows.items()]
    show(title, [""] + arms, body + ([extra] if extra else []))


def run_fixture(name, schema, instances, arms, rounds, notes):
    size, calls = os.path.getsize(instances), instance_count(instances)
    out = {}
    for form in FORMS:
        live, accepted, marks = [], {}, {}
        for arm in arms:
            try:
                _, _, accepted[arm], marks[arm] = timed(command(arm, form, schema, instances), True)
                live.append(arm)
            except guard.Failed as e:
                notes.append(f"{name} {form} {arm}: {e}")
        want = statistics.mode([marks[a] for a in live]) if live else None
        for a in live:
            if marks[a] != want:
                notes.append(f"{name} {form} {a}: differs from the other arms at instance {first_difference(marks[a], want)}")
        agree = {a: marks[a] == want for a in live}
        live = [a for a in live if agree[a]]
        best, ns = dict.fromkeys(live, 0.0), dict.fromkeys(live)
        for _ in range(rounds):
            for arm in live:
                try:
                    g, t, _, _ = timed(command(arm, form, schema, instances))
                except guard.Failed as e:
                    notes.append(f"{name} {form} {arm}: {e}")
                    continue
                if g > best[arm]:
                    best[arm], ns[arm] = g, t
        gb = {a: b for a, b in best.items() if b > 0}
        ins = {}
        for arm in live:
            try:
                ins[arm] = per_call(command(arm, form, schema, instances), size, calls)
            except guard.Failed as e:
                notes.append(f"{name} {form} {arm} instructions: {e}")
        out[form] = (gb, {a: ns[a] / calls / 1000 for a in gb}, ins, accepted if form == "verdict" else None, agree)
    print(f"fixture {name}", flush=True)
    return calls, out


GENERATED = ["logs.json", "logs.ndjson", "schema/logs.schema.json", "schema/twitter.schema.json", "schema/citm.schema.json",
             "schema/applicator.schema.json", "schema/applicator.ndjson", "schema/twitter.json", "schema/citm.json",
             "schema/logs.json"]


def main(rounds, wanted, arm_names):
    sources.fetch("schemas")
    with contextlib.redirect_stdout(io.StringIO()):
        sources.generate(GENERATED, False)
    names = fixtures()
    unknown = [w for w in wanted if w not in names]
    if unknown:
        sys.exit(f"no fixture {' '.join(unknown)}: the fixtures are {' '.join(names)}")
    arms = list(built_arms(arm_names))
    if "stury" not in arms:
        sys.exit("the stury arm is not built")
    print(machine())
    print(spec()["lane"]["legend"].format(rounds=rounds))
    print("load average at the start: %.1f %.1f %.1f on %d cores" % (*os.getloadavg(), os.cpu_count()))
    notes, results = [], {}
    with guard.locked():
        for name, (schema, instances) in names.items():
            if not wanted or name in wanted:
                results[name] = run_fixture(name, schema, instances, arms, rounds, notes)
    for i, form in enumerate(FORMS):
        parts = [{n: r[1][form][k] for n, r in results.items()} for k in range(3)]
        shown = [a for a in arms if any(a in c for c in parts[0].values())]
        grid(f"{form}, parse + judge, GB/s of the instance text", parts[0], shown, extra=geomean_row(parts[0], shown))
        grid(f"{form}, us per call", parts[1], shown)
        grid(f"{form}, instructions per call", parts[2], shown)
    rows = []
    for n, (calls, out) in results.items():
        accepted, agree = out["verdict"][3], out["verdict"][4]
        rows.append([n, calls, *[accepted.get(a) for a in arms],
                     "yes" if len(agree) == len(arms) and all(agree.values()) else "NO"])
    show("instances accepted in the verdict form, and whether every instance's verdict agrees",
         ["", "instances", *arms, "agree"], rows)
    for n in notes:
        print("left out: " + n)
    return 0
