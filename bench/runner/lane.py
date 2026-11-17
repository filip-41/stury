import fnmatch
import json
import os
import statistics
import sys

from . import guard, probes
from .tables import machine, show


PROBE_ARGS = ["{sub}", "{file}"]


class Blank(dict):
    def __missing__(self, key):
        return ""


def expand(template, row):
    """The arguments of a template with each `{name}` filled from ROW. An argument that comes out empty is dropped."""
    return [s for a in template if (s := a.format_map(Blank(row)))]


def root_key(path, which):
    with open(path) as f:
        keys = list(json.load(f))
    return {"first": keys[0], "middle": keys[len(keys) // 2], "last": keys[-1]}[which]


def rows_of(group, variant):
    """The group's rows with the variant's values merged in, each with its fixture's path and name, and a key written
    `@first`, `@middle` or `@last` replaced by that root key of the fixture."""
    rows = []
    for entry in group["rows"]:
        row = {"file": entry} if isinstance(entry, str) else dict(entry)
        row = {**variant, **row}
        row["name"] = row["file"]
        row["file"] = probes.fixture(row["file"])
        row.setdefault("label", row["name"])
        if row.get("key", "").startswith("@"):
            row["key"] = root_key(row["file"], row["key"][1:])
            row["dotkey"] = "." + row["key"]
        if "largest" in row and os.environ.get("ANSWER_BATCH"):
            row["largest"] = os.environ["ANSWER_BATCH"]
        rows.append(row)
    return rows


def command(lane, arm, row):
    sub = arm.get("sub", row.get("sub", ""))
    return [str(probes.binary(lane, arm["source"])), *expand(arm.get("args", PROBE_ARGS), {**row, "sub": sub})]


def runs_on(name, arm, row):
    """Whether the arm reads the row: the row names it, its files pattern matches the fixture, and its `when` values
    are the row's."""
    return ((not row.get("arms") or name in row["arms"])
            and any(fnmatch.fnmatch(row["name"], p) for p in arm.get("files", ["*"]))
            and all(row.get(k, "") == v for k, v in arm.get("when", {}).items()))


def best_of(values, metric):
    return max(values) if metric == "gb_per_s" else min(values)


def compare(title, row, found, arms):
    """Exits unless every checked arm printed the same check for the row."""
    checked = {a: m.check for a, m in found.items() if not any(fnmatch.fnmatch(row["name"], u) for u in arms[a].get("unchecked", []))}
    if not row.get("unchecked") and len(set(checked.values())) > 1:
        sys.exit(f"checks disagree on {title} {row['label']}: " + " ".join(f"{a}={c}" for a, c in checked.items()))
    print(f"check {title:18} {row['label']:22} " + " ".join(f"{a}={c}" for a, c in checked.items()), flush=True)


def run_variant(lane, group, variant, arms, rounds):
    title = " ".join(x for x in (group.get("title", ""), variant.get("title", "")) if x)
    metric = group.get("metric", "gb_per_s")
    results = []
    for row in rows_of(group, variant):
        live = {a: arms[a] for a in group.get("arms", arms) if a in arms and runs_on(a, arms[a], row)}
        cmds = {a: command(lane, arm, row) for a, arm in live.items()}
        samples = {a: [] for a in cmds}
        for r in range(rounds):
            found = {}
            for a, cmd in cmds.items():
                try:
                    found[a] = probes.measure(cmd)
                except guard.Failed as e:
                    sys.exit(f"failed {' '.join(cmd)}: {e}")
                samples[a].append(found[a])
            if r == 0:
                compare(title, row, found, arms)
        results.append((row, samples))
    return title, metric, results


def cell(samples, metric):
    return best_of([getattr(s, metric) for s in samples], metric)


def tables_of(group, results, title, metric):
    for t in group.get("tables", [{}]):
        names = t.get("files")
        rows = [(r, s) for r, s in results if not names or r["name"] in names]
        wanted = t.get("arms") or group.get("arms") or list(results[0][1])
        columns = [a for a in wanted if any(a in s for _, s in rows)]
        if not columns:
            continue
        throughput = t.get("throughput", False)
        headers = ["", *[h for a in columns for h in ((f"{a} ns", "GB/s") if throughput else (a,))]]
        body = []
        for row, samples in rows:
            line = [row["label"]]
            for a in columns:
                if a not in samples:
                    line += [None] * (2 if throughput else 1)
                    continue
                v = cell(samples[a], metric)
                line += [int(v), os.path.getsize(row["file"]) / v] if throughput else [v]
            body.append(line)
        show(f"{title} {t.get('title', '')}".strip() + (" GB/s" if metric == "gb_per_s" else ""), headers, body)
        if group.get("rss"):
            show(f"{title} RSS MiB", headers[:len(columns) + 1],
                 [[row["label"], *[statistics.median(m.peak_mib for m in samples[a]) if a in samples else None
                                   for a in columns]] for row, samples in rows])


def main(lane, rounds, wanted, arm_names):
    spec = probes.lane_toml(lane)
    arms = spec["arm"]
    if arm_names:
        unknown = [a for a in arm_names if a not in arms]
        if unknown:
            sys.exit(f"no arm {' '.join(unknown)} in {lane}: the arms are {' '.join(arms)}")
        arms = {a: arms[a] for a in arm_names}
    for name, arm in arms.items():
        if not probes.binary(lane, arm["source"]).exists():
            print(f"left out: {name} ({probes.binary(lane, arm['source']).name} is not built)")
    arms = {n: a for n, a in arms.items() if probes.binary(lane, a["source"]).exists()}
    print(machine())
    print(spec["lane"]["legend"].format(rounds=rounds))
    with guard.locked():
        for group in spec["group"]:
            if wanted:
                group = {**group, "rows": [r for r in group["rows"] if (r if isinstance(r, str) else r.get("label", r["file"]))
                                           in wanted or (r if isinstance(r, str) else r["file"]) in wanted]}
                if not group["rows"]:
                    continue
            for variant in group.get("variant", [{}]):
                title, metric, results = run_variant(lane, group, variant, arms, rounds)
                tables_of(group, results, title, metric)
    return 0
