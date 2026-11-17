import collections
import decimal
import json
import math
import re
import shutil
import statistics
import sys
import tomllib
import shlex

from tabulate import tabulate

from . import guard
from .layout import BENCH, BUILD, FIXTURES, ROOT
from .tables import machine

OUT = BUILD / "cli"
STRIP = BENCH / "lanes" / "cli" / "strip_jsonc.awk"
WARMUPS = 2


def jsonc(src, dst):
    """Writes logs.json as JSONC to DST: pretty-printed, with a line comment after every opening bracket and a trailing
    comma before every closing one."""
    lines = json.dumps(json.load(open(src)), indent=2).split("\n")
    out = []
    for i, line in enumerate(lines):
        following = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if following[:1] in ("}", "]") and line.rstrip()[-1:] not in ("{", "["):
            line += ","
        out.append(line)
        if line.rstrip()[-1:] in ("{", "["):
            out.append("// note")
    dst.write_text("\n".join(out) + "\n")


def command(spec, case, tool, fields):
    if tool in case.get("cmd", {}):
        template = case["cmd"][tool]
    else:
        template = spec["template"][tool]
    values = {**case, **fields}
    return re.sub(r"\{(S|jsonc|strip|stury|yq|flags|filter|file)\}", lambda m: values.get(m.group(1), ""), template)


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


def as_float(d):
    return "number:" + repr(float(d))


def number(d):
    """One string for every spelling of D's value. The context keeps every digit, so two long numbers that differ only
    in late digits stay distinct."""
    ctx = decimal.Context(prec=len(d.as_tuple().digits) + 1, Emax=decimal.MAX_EMAX, Emin=decimal.MIN_EMIN)
    return "number:" + str(d.normalize(ctx))


def answer(text, raw, spell=None):
    return text.splitlines() if raw else [json.dumps(v, sort_keys=True, default=spell or number) for v in values(text)]


def verdicts_of(case, answers):
    """Each tool's verdict against stury's answer: `same`, `same, reordered` (gojq iterates an object's members in key
    order), `same as float64` (yq writes 43.420273000000009 as 43.42027300000001) or `DIFFERS`."""
    raw = case["name"].endswith("_raw")
    want = answer(answers["stury"], raw)
    if not want and not case["name"].startswith("validate"):
        sys.exit(f"stury printed nothing for case {case['name']}: nothing to check the others against")
    out = {"stury": f"{len(want)} answers"}
    for tool, text in answers.items():
        if tool == "stury":
            continue
        got = answer(text, raw)
        if got == want:
            out[tool] = "same"
        elif sorted(got) == sorted(want):
            out[tool] = "same, reordered"
        elif not raw and sorted(answer(text, raw, as_float)) == sorted(answer(answers["stury"], raw, as_float)):
            out[tool] = "same as float64"
        else:
            out[tool] = f"DIFFERS ({len(got)} answers)"
    return out


def time_case(case, commands, rounds, runs):
    """Hyperfine over the case's tools, ROUNDS times with the tool order rotated each round. Returns each tool's
    timings in seconds."""
    tools, times = list(commands), collections.defaultdict(list)
    for r in range(rounds):
        order = [tools[(i + r) % len(tools)] for i in range(len(tools))]
        export = OUT / f"{case['name']}.json"
        args = ["hyperfine", "-N", "-w", str(WARMUPS), "-r", str(runs), "--style", "none", "--export-json", str(export)]
        for t in order:
            args += ["-n", t, commands[t]]
        guard.run(args, cwd=FIXTURES)
        for result in json.load(open(export))["results"]:
            times[result["command"]] += result["times"]
    return times


def report(table, summary):
    ratios, differs = collections.defaultdict(list), collections.Counter()
    rows = []
    for case, (times, verdicts) in table.items():
        base = statistics.median(times["stury"])
        for tool in sorted(times, key=lambda t: t != "stury"):
            t = statistics.median(times[tool])
            verdict = verdicts.get(tool, "")
            rows.append([case, tool, t * 1e3, t / base, verdict])
            if tool != "stury":
                if verdict.startswith("same"):
                    ratios[tool].append(t / base)
                else:
                    differs[tool] += 1
    lines = [machine(), "", tabulate(rows, ["case", "tool", "median ms", "x stury", "answer"], tablefmt="github", floatfmt=".2f"), ""]
    summary_rows = []
    for tool in sorted(set(ratios) | set(differs)):
        rs = ratios[tool] or [math.nan]
        summary_rows.append([tool, len(ratios[tool]), statistics.geometric_mean(rs) if ratios[tool] else math.nan, min(rs), differs[tool]])
    lines.append(tabulate(summary_rows, ["tool", "cases", "geomean x stury", "min x stury", "answer differs"], tablefmt="github", floatfmt=".2f"))
    text = "\n".join(lines) + "\n"
    (OUT / "report.md").write_text(text)
    print(text, end="")
    return not differs


def main(rounds, runs, suite, only):
    with open(BENCH / "lanes" / "cli" / "cases.toml", "rb") as f:
        spec = tomllib.load(f)
    stury = ROOT / "build" / "stury"
    if not stury.exists():
        sys.exit(f"no {stury}: run make build-cli")
    cases = [c for c in spec["case"] if c["suite"] == suite and re.search(only, c["name"])]
    needed = {"hyperfine", *(t for c in cases for t in c["tools"] if t != "stury")}
    missing = sorted(t for t in needed if not shutil.which(t))
    if missing:
        sys.exit(f"no {' '.join(missing)} on PATH: the comparison needs every tool")
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    fields = {"S": str(stury), "jsonc": str(OUT / "logs.jsonc"), "strip": str(STRIP)}
    jsonc(FIXTURES / "logs.json", OUT / "logs.jsonc")
    table = {}
    with guard.locked():
        for case in cases:
            commands = {t: command(spec, case, t, fields) for t in case["tools"]}
            answers = {t: guard.run(shlex.split(c), cwd=FIXTURES).out for t, c in commands.items()}
            table[case["name"]] = (time_case(case, commands, rounds, runs), verdicts_of(case, answers))
            print(f"{case['name']}: timed", file=sys.stderr)
    return 0 if report(table, spec) else 1
