#!/usr/bin/env python3
"""yaml-test-suite's cases through the command line: every case with an in.json, read with `--from yaml -c .`, must
print the values of in.json, and every case with an error marker must be refused by `check --from yaml` with the exit
status of a parse error.

    python3 cmd/stury/test/yaml_suite.py [build/stury]

A case is skipped for a reason listed in SKIP. Numbers are compared as numbers, since YAML spells floats as it likes.
"""

import json
import math
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
CASES = os.path.join(ROOT, "yaml", "test", "suite")
EXIT_PARSE = 5

# The suite accepts a mapping with two empty keys, and stury refuses a key that repeats.
SKIP = {"2JQS"}


def values(text):
    """The JSON values of a text, one after another."""
    decoder = json.JSONDecoder()
    out, at = [], 0
    while True:
        while at < len(text) and text[at] in " \t\r\n":
            at += 1
        if at >= len(text):
            return out
        value, at = decoder.raw_decode(text, at)
        out.append(value)


def same(got, want):
    if isinstance(want, dict):
        return isinstance(got, dict) and set(got) == set(want) and all(same(got[k], want[k]) for k in want)
    if isinstance(want, list):
        return isinstance(got, list) and len(got) == len(want) and all(same(g, w) for g, w in zip(got, want))
    if isinstance(want, bool) or isinstance(got, bool):
        return got is want
    if isinstance(want, float) and isinstance(got, (int, float)):
        return got == want or math.isnan(got) and math.isnan(want)
    return got == want


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def valid_case(binary, name):
    case = os.path.join(CASES, name)
    run = subprocess.run([binary, "--from", "yaml", "-c", ".", os.path.join(case, "in.yaml")], capture_output=True, timeout=20)
    if run.returncode != 0:
        return f"{name}: exit {run.returncode}: {run.stderr.decode(errors='replace').strip()}"
    try:
        got = values(run.stdout.decode())
    except ValueError:
        return f"{name}: output is not JSON: {run.stdout[:80]!r}"
    want = values(read(os.path.join(case, "in.json")))
    if not same(got, want):
        return f"{name}: {run.stdout.decode()[:200].strip()} differs from {json.dumps(want)[:200]}"
    return ""


def invalid_case(binary, name):
    run = subprocess.run([binary, "check", "--from", "yaml", os.path.join(CASES, name, "in.yaml")], capture_output=True, timeout=20)
    if run.returncode != EXIT_PARSE:
        return f"{name}: check exits {run.returncode}, not {EXIT_PARSE}"
    return ""


def main():
    binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "stury"))
    names = sorted(n for n in os.listdir(CASES) if os.path.isfile(os.path.join(CASES, n, "in.yaml")) and n not in SKIP)
    jobs = []
    for n in names:
        if os.path.exists(os.path.join(CASES, n, "error")):
            jobs.append((invalid_case, n))
        elif os.path.exists(os.path.join(CASES, n, "in.json")):
            jobs.append((valid_case, n))
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda job: job[0](binary, job[1]), jobs))
    failures = [r for r in results if r]
    for line in failures:
        print("FAIL", line)
    print(f"yaml-test-suite through the command line: {len(jobs) - len(failures)} of {len(jobs)} cases pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
