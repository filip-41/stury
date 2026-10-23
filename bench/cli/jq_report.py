"""Writes the report for jq_compare.sh and csv_compare.sh: whether every tool printed stury's answer, then
the timings.

    python3 bench/cli/jq_report.py OUT_DIR

OUT_DIR/answers holds CASE.TOOL.txt, one file per tool's stdout. A case whose name ends in `_raw` prints raw
strings, compared line by line. Every other case prints JSON values, compact or pretty, compared after
decoding, so different spellings of one value (escapes, `1E+2` for `1e2`, yq's `396` for `396.0`) are equal.
A tool whose values match only as a multiset passes as "reordered" (gojq iterates an object's members in key
order). A tool whose numbers match only when read as float64 passes as "same as float64" (yq writes
`43.420273000000009` as `43.42027300000001`: the same double, without the literal's digits).
OUT_DIR/CASE.roundN.json are hyperfine's exports, one per round. The table gives each tool's median over all
rounds and its ratio to stury's. The summary gives, per tool, the geometric mean and the minimum of those
ratios over the cases where it matched stury, and the number of cases where it did not.
Writes OUT_DIR/report.md and exits 1 when any tool's answer differs.
"""
import collections
import decimal
import glob
import json
import math
import os
import statistics
import sys


def values(text):
    dec = json.JSONDecoder(parse_float=decimal.Decimal, parse_int=decimal.Decimal)
    out, i = [], 0
    while True:
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
        if i == len(text):
            return out
        v, i = dec.raw_decode(text, i)
        out.append(v)


def answer(path, raw, spell=None):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return text.splitlines() if raw else [json.dumps(v, sort_keys=True, default=spell or number) for v in values(text)]


def as_float(d):
    return "number:" + repr(float(d))


def number(d):
    """Returns one string for every spelling of D's value. The context keeps every digit, so two long numbers
    that differ only in late digits stay distinct."""
    digits = len(d.as_tuple().digits)
    ctx = decimal.Context(prec=digits + 1, Emax=decimal.MAX_EMAX, Emin=decimal.MIN_EMIN)
    return "number:" + str(d.normalize(ctx))


def check(root):
    """Returns ({case: {tool: verdict}}, whether every tool matched stury)."""
    files = collections.defaultdict(dict)
    for name in sorted(os.listdir(root)):
        case, tool, _ = name.rsplit(".", 2)
        files[case][tool] = os.path.join(root, name)
    verdicts, ok = {}, True
    for case, tools in files.items():
        if "stury" not in tools:
            raise SystemExit("no stury answer for case %s in %s: nothing to check the others against" % (case, root))
        raw = case.endswith("_raw")
        stury = tools.pop("stury")
        want = answer(stury, raw)
        if not want and not case.startswith("validate"):  # validation prints nothing on success
            raise SystemExit("stury printed nothing for case %s: nothing to check the others against" % case)
        verdicts[case] = {"stury": "%d answers" % len(want)}
        for tool, path in tools.items():
            got = answer(path, raw)
            if got == want:
                verdicts[case][tool] = "same"
            elif sorted(got) == sorted(want):
                verdicts[case][tool] = "same, reordered"
            elif not raw and sorted(answer(path, raw, as_float)) == sorted(answer(stury, raw, as_float)):
                verdicts[case][tool] = "same as float64"
            else:
                verdicts[case][tool] = "DIFFERS (%d answers)" % len(got)
                ok = False
    return verdicts, ok


def medians(out, case):
    """Returns {tool: median seconds} over every round of CASE."""
    times = collections.defaultdict(list)
    for path in glob.glob(os.path.join(out, case + ".round*.json")):
        with open(path) as f:
            for r in json.load(f)["results"]:
                times[r["command"]] += r["times"]
    return {tool: statistics.median(t) for tool, t in times.items()}


def main(out):
    answers = os.path.join(out, "answers")
    if not os.path.isdir(answers):
        raise SystemExit("%s has no answers/ directory; run bench/cli/jq_compare.sh first" % out)
    verdicts, ok = check(answers)
    lines = ["| case | tool | median ms | × stury | answer |", "| --- | --- | ---: | ---: | --- |"]
    ratios, differs = collections.defaultdict(list), collections.Counter()
    for case in verdicts:
        runs = medians(out, case)
        base = runs["stury"]
        for tool, t in sorted(runs.items(), key=lambda kv: kv[0] != "stury"):
            verdict = verdicts[case].get(tool, "")
            lines.append("| %s | %s | %.1f | %.2f | %s |" % (case, tool, t * 1e3, t / base, verdict))
            if tool == "stury":
                continue
            if verdict.startswith("same"):
                ratios[tool].append(t / base)
            else:
                differs[tool] += 1
    lines += ["", "| tool | cases | geomean × stury | min × stury | answer differs |",
              "| --- | ---: | ---: | ---: | ---: |"]
    for tool in sorted(set(ratios) | set(differs)):
        rs = ratios[tool] or [math.nan]
        geo = math.exp(sum(map(math.log, rs)) / len(rs))
        lines.append("| %s | %d | %.2f | %.2f | %d |" % (tool, len(ratios[tool]), geo, min(rs), differs[tool]))
    text = "\n".join(lines) + "\n"
    with open(os.path.join(out, "report.md"), "w") as f:
        f.write(text)
    print(text, end="")
    if not ok:
        print("an answer differs from stury's")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python3 bench/cli/jq_report.py OUT_DIR")
    sys.exit(main(sys.argv[1]))
