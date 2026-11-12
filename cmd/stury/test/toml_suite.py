#!/usr/bin/env python3
"""toml-test's cases through the command line: every valid case of the list each TOML version is held to, read with
`--from toml` and written as tagged JSON by toml_tagged.jq, must equal the case's .json, and every invalid case must be
refused by `check --from toml` with the exit status of a parse error. The command line reads TOML 1.1, so the valid
cases of both lists run, and the invalid cases of 1.1's.

    python3 cmd/stury/test/toml_suite.py [build/stury]

Datetimes are compared as toml-test compares them: the separator between date and time, the case of the offset's Z,
seconds that 1.1 leaves out, and zeros at the end of a fraction are not differences. Floats are compared as numbers.
"""

import json
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
CASES = os.path.join(ROOT, "toml", "test", "conformance", "toml-test")
FILTER = os.path.join(HERE, "toml_tagged.jq")
EXIT_PARSE = 5
DATETIMES = {"datetime", "datetime-local", "date-local", "time-local"}


def listed(version):
    with open(os.path.join(CASES, f"files-toml-{version}")) as f:
        return {line.strip() for line in f if line.strip().endswith(".toml")}


def datetime_form(text):
    text = text.replace("t", "T").replace("z", "Z")
    text = re.sub(r"^(\d{4}-\d\d-\d\d) (?=\d)", r"\1T", text)
    text = re.sub(r"(^|T)(\d\d:\d\d)(?=$|[Z+-])", r"\1\2:00", text)
    return re.sub(r"\.(\d*?)0*(?=$|[Z+-])", lambda m: "." + m.group(1) if m.group(1) else "", text)


def same(got, want):
    """Whether tagged value `got` equals `want`, as toml-test's comparison does."""
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
    return got == want


def valid_case(binary, name):
    path = os.path.join(CASES, name)
    run = subprocess.run([binary, "--from", "toml", "-c", "-f", FILTER, path], capture_output=True, timeout=20)
    if run.returncode != 0:
        return f"{name}: exit {run.returncode}: {run.stderr.decode(errors='replace').strip()}"
    with open(path[: -len(".toml")] + ".json", encoding="utf-8") as f:
        want = json.load(f)
    try:
        got = json.loads(run.stdout)
    except ValueError:
        return f"{name}: output is not JSON: {run.stdout[:80]!r}"
    if not same(got, want):
        return f"{name}: {run.stdout.decode()[:200].strip()} differs from {json.dumps(want)[:200]}"
    return ""


def invalid_case(binary, name):
    run = subprocess.run([binary, "check", "--from", "toml", os.path.join(CASES, name)], capture_output=True, timeout=20)
    if run.returncode != EXIT_PARSE:
        return f"{name}: check exits {run.returncode}, not {EXIT_PARSE}"
    return ""


def main():
    binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "stury"))
    # 1.1 reads every text 1.0 does, so a valid case of either list reads, and an invalid case of 1.1's list is refused.
    newest = listed("1.1.0")
    valid = sorted(n for n in newest | listed("1.0.0") if n.startswith("valid/"))
    invalid = sorted(n for n in newest if n.startswith("invalid/"))
    jobs = [(valid_case, n) for n in valid] + [(invalid_case, n) for n in invalid]
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda job: job[0](binary, job[1]), jobs))
    failures = [r for r in results if r]
    for line in failures:
        print("FAIL", line)
    print(f"toml-test through the command line: {len(jobs) - len(failures)} of {len(jobs)} cases pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
