#!/usr/bin/env python3
"""schema_oracle.py: the Python `jsonschema` package, the oracle for the schema lane's verdicts.

    schema_oracle.py [--instances N] [FIXTURE...]

Fixtures: for each of the lane's 19 schemas (bench/schema.py), jsonschema judges the first N instances (1000) and every
arm that judges a schema (Blaze, jsonschema-rs, boon) runs the same prefix; each instance's verdict must be equal, and
the first that differs is named. stury's arm is `json.validate` until its schema check lands, so it is left out.
--suite: jsonschema is also held to the expected verdicts of every required case of the vendored JSON-Schema-Test-Suite,
drafts 4 to 2020-12, so a disagreement above is the arm's. A case whose schema jsonschema cannot compile or resolve is
counted apart, not as a failure.

Run it with the pinned package: make diff-schema, which is
  uv run --offline --no-project --with jsonschema==4.26.0 python3 bench/schema_oracle.py
Exits 1 on a difference. Formats are not asserted, as in the lane.
"""
import argparse, glob, importlib.metadata, itertools, json, os, sys, tempfile

import jsonschema
import referencing, referencing.jsonschema

import schema as lane
from doc import select_arms, spawn

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = os.path.join(ROOT, "json", "test", "conformance", "JSON-Schema-Test-Suite", "tests")
REMOTES = os.path.join(os.path.dirname(SUITE), "remotes")
BASE = "http://localhost:1234/"
DRAFTS = {"draft4": jsonschema.Draft4Validator, "draft6": jsonschema.Draft6Validator, "draft7": jsonschema.Draft7Validator,
          "draft2019-09": jsonschema.Draft201909Validator, "draft2020-12": jsonschema.Draft202012Validator}


def retrieve(uri):
    """The suite's remote documents, which its runners serve on localhost:1234."""
    with open(os.path.join(REMOTES, uri.removeprefix(BASE)), "rb") as f:
        return referencing.Resource.from_contents(json.load(f), default_specification=referencing.jsonschema.DRAFT202012)


def fixture_verdicts(name, limit):
    """Returns (the oracle's verdicts, {arm: its verdicts}) on the first LIMIT instances of a fixture, each a string of
    one 0 or 1 per instance."""
    schema_path, instances_path = lane.FIXTURES[name]
    with open(schema_path, "rb") as f:
        schema = json.load(f)
    lines = instances_path.endswith((".jsonl", ".ndjson"))
    with open(instances_path, "rb") as f:
        texts = list(itertools.islice((l for l in f if l.strip()), limit)) if lines else [f.read()]
    validator = jsonschema.validators.validator_for(schema)(schema)
    mine = "".join("1" if validator.is_valid(json.loads(t)) else "0" for t in texts)
    with tempfile.NamedTemporaryFile("wb", suffix=".jsonl" if lines else ".json") as tmp, \
            tempfile.NamedTemporaryFile("r") as marks:
        tmp.write(b"".join(t if t.endswith(b"\n") else t + b"\n" for t in texts))
        tmp.flush()
        theirs = {}
        for arm in lane.judging(HAVE):
            spawn(lane.command(arm, "verdict", schema_path, tmp.name), {"BENCH_PASSES": "1", "BENCH_VERDICTS": marks.name})
            theirs[arm] = open(marks.name).read()
    return mine, theirs


def suite_report():
    """Cases per draft the oracle gets as the suite expects, wrong, and cannot compile."""
    bad = []
    for draft, cls in DRAFTS.items():
        ok = wrong = unusable = 0
        for path in sorted(glob.glob(os.path.join(SUITE, draft, "*.json"))):
            with open(path, "rb") as f:
                groups = json.load(f)
            for group in groups:
                try:
                    validator = cls(group["schema"], registry=referencing.Registry(retrieve=retrieve))
                except Exception:
                    unusable += len(group["tests"])
                    continue
                for test in group["tests"]:
                    try:
                        got = validator.is_valid(test["data"])
                    except Exception:
                        unusable += 1
                        continue
                    if got == test["valid"]:
                        ok += 1
                    else:
                        wrong += 1
                        bad.append(f"{draft}/{os.path.basename(path)}: {group['description']}: {test['description']}")
        print(f"suite {draft:13} as expected {ok:5}  wrong {wrong:3}  unusable {unusable:3}")
    return bad


def main():
    global HAVE
    ap = argparse.ArgumentParser()
    ap.add_argument("--instances", type=int, default=1000)
    ap.add_argument("--suite", action="store_true", help="also hold the oracle to the JSON-Schema-Test-Suite")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    unknown = [n for n in a.names if n not in lane.FIXTURES]
    if unknown:
        ap.error("unknown fixture: " + ", ".join(unknown))
    HAVE = select_arms(lane.BIN, "bench-schema-peers")
    print("jsonschema", importlib.metadata.version("jsonschema"))
    differ = []
    for name in a.names or lane.FIXTURES:
        mine, theirs = fixture_verdicts(name, a.instances)
        flag = [k for k, v in theirs.items() if v != mine]
        print(f"{name:16} {len(mine):5} instances  oracle accepts {mine.count('1')}, " + " ".join(
            f"{k} {v.count('1')}" for k, v in theirs.items()) + (f"  DIFFERS: {' '.join(flag)}" if flag else ""))
        differ += [f"{name}: {k} differs from the oracle at instance {lane.first_difference(theirs[k], mine)}" for k in flag]
    if a.suite:
        for w in suite_report():
            print("oracle against the suite: " + w)
    for d in differ:
        print("differs: " + d, file=sys.stderr)
    return 1 if differ else 0


HAVE = []

if __name__ == "__main__":
    sys.exit(main())
