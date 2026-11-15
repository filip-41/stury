#!/usr/bin/env python3
"""toml-test's and yaml-test-suite's valid cases through the command line, and the refusal of an invalid one. Each valid
case is read by the CLI and must equal the case's JSON: TOML as the tagged JSON of toml_tagged.jq, YAML as in.json. The
library suites judge every invalid case, so the command line's refusal (`check`, the exit status of a parse error, a
message) is proved here by the first few of each format.

    python3 cmd/stury/test/conformance_suite.py [build/stury]

TOML datetimes are compared as toml-test compares them: the separator between date and time, the case of the offset's
Z, seconds that 1.1 leaves out, and zeros at the end of a fraction are not differences. Floats are compared as numbers,
since YAML spells them as it likes. The command line reads TOML 1.1, so the valid cases of both lists run.
"""

import json
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from harness import ROOT, values

HERE = os.path.dirname(os.path.abspath(__file__))
TOML = os.path.join(ROOT, "toml", "test", "conformance", "toml-test")
YAML = os.path.join(ROOT, "yaml", "test", "suite")
FILTER = os.path.join(HERE, "toml_tagged.jq")
EXIT_PARSE = 5
REFUSED = 3
DATETIMES = {"datetime", "datetime-local", "date-local", "time-local"}
# The suite accepts a mapping with two empty keys, and stury refuses a key that repeats.
YAML_SKIP = {"2JQS"}


def datetime_form(text):
    text = text.replace("t", "T").replace("z", "Z")
    text = re.sub(r"^(\d{4}-\d\d-\d\d) (?=\d)", r"\1T", text)
    text = re.sub(r"(^|T)(\d\d:\d\d)(?=$|[Z+-])", r"\1\2:00", text)
    return re.sub(r"\.(\d*?)0*(?=$|[Z+-])", lambda m: "." + m.group(1) if m.group(1) else "", text)


def same(got, want):
    """Whether `got` equals `want`: a toml-test tagged value as toml-test compares it, a number as a number."""
    if isinstance(want, dict) and set(want) == {"type", "value"} and isinstance(want["value"], str):
        if not (isinstance(got, dict) and set(got) == {"type", "value"} and got["type"] == want["type"]):
            return False
        if want["type"] in DATETIMES:
            return datetime_form(got["value"]) == datetime_form(want["value"])
        if want["type"] == "float":
            try:
                a, b = float(got["value"]), float(want["value"].replace("_", ""))
            except ValueError:
                return False
            return a == b or math.isnan(a) and math.isnan(b)
        return got["value"] == want["value"]
    if isinstance(want, dict):
        return isinstance(got, dict) and set(got) == set(want) and all(same(got[k], want[k]) for k in want)
    if isinstance(want, list):
        return isinstance(got, list) and len(got) == len(want) and all(same(g, w) for g, w in zip(got, want))
    if isinstance(want, bool) or isinstance(got, bool):
        return got is want
    if isinstance(want, float) and isinstance(got, (int, float)):
        return got == want or math.isnan(got) and math.isnan(want)
    return got == want


def toml_cases():
    """(valid, invalid): each valid case is (name, argv after the binary, the values it prints), each invalid one a path.
    1.1 reads every text 1.0 does, so a valid case of either list reads, and an invalid case of 1.1's list is refused."""

    def listed(version):
        with open(os.path.join(TOML, f"files-toml-{version}")) as f:
            return {line.strip() for line in f if line.strip().endswith(".toml")}

    newest = listed("1.1.0")
    valid = []
    for name in sorted(n for n in newest | listed("1.0.0") if n.startswith("valid/")):
        path = os.path.join(TOML, name)
        with open(path[: -len(".toml")] + ".json", encoding="utf-8") as f:
            valid.append((name, ["--from", "toml", "-c", "-f", FILTER, path], [json.load(f)]))
    return valid, [os.path.join(TOML, n) for n in sorted(newest) if n.startswith("invalid/")]


def yaml_cases():
    valid, invalid = [], []
    for name in sorted(n for n in os.listdir(YAML) if os.path.isfile(os.path.join(YAML, n, "in.yaml")) and n not in YAML_SKIP):
        case = os.path.join(YAML, name)
        if os.path.exists(os.path.join(case, "error")):
            invalid.append(os.path.join(case, "in.yaml"))
        elif os.path.exists(os.path.join(case, "in.json")):
            with open(os.path.join(case, "in.json"), encoding="utf-8") as f:
                valid.append((name, ["--from", "yaml", "-c", ".", os.path.join(case, "in.yaml")], values(f.read())))
    return valid, invalid


FORMATS = {"toml": toml_cases, "yaml": yaml_cases}


def valid_case(binary, case):
    name, argv, want = case
    run = subprocess.run([binary, *argv], capture_output=True, timeout=20)
    if run.returncode != 0:
        return f"{name}: exit {run.returncode}: {run.stderr.decode(errors='replace').strip()}"
    try:
        got = values(run.stdout.decode())
    except ValueError:
        return f"{name}: output is not JSON: {run.stdout[:80]!r}"
    if not same(got, want):
        return f"{name}: {run.stdout.decode()[:200].strip()} differs from {json.dumps(want)[:200]}"
    return ""


def invalid_case(binary, fmt, path):
    run = subprocess.run([binary, "check", "--from", fmt, path], capture_output=True, timeout=20)
    if run.returncode != EXIT_PARSE or not run.stderr:
        return f"{path}: check exits {run.returncode} with {len(run.stderr)} bytes of message, not {EXIT_PARSE} and a message"
    return ""


def main():
    binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "stury"))
    jobs = []
    for fmt, cases in FORMATS.items():
        valid, invalid = cases()
        jobs += [(valid_case, binary, c) for c in valid] + [(invalid_case, binary, fmt, p) for p in invalid[:REFUSED]]
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda job: job[0](*job[1:]), jobs))
    failures = [r for r in results if r]
    for line in failures:
        print("FAIL", line)
    print(f"toml-test and yaml-test-suite through the command line: {len(jobs) - len(failures)} of {len(jobs)} cases pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
