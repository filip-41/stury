#!/usr/bin/env python3
"""`stury check --filter` against the JSON Schema Test Suite's draft 2020-12 schemas and the schema fixtures, judged
on samples of each schema and a fixture's own instances:

- `.emial` is refused on a schema that lists members, and is not refused where an object with an `emial` member passes
  the schema: a schema that lists no member and refuses it, or one that does not refuse it and that no sample object
  with an `emial` member passes, fails, but where `propertyNames` or `maxProperties` bound the names.
- A filter is refused only where no sample runs it: a kind refusal where a sample runs it without an error, or a member
  refusal of a name a sample has, fails. A filter is accepted only where some sample takes it: one that every sample
  fails with a kind error fails.
- What a filter writes on the samples passes the schema the typing writes for it, on every filter of FILTERS and the
  reads of the members the samples have.
- `type` on a string of `contentEncoding: base64` is "bytes" where the input format reads byte strings (types_probe.odin).
- A recursive schema and a recursive filter end inside a fixed budget.

    types_law.py BINARY [--odin PATH] [--fixtures DIR] [--count N]
"""

import argparse
import concurrent.futures
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

from harness import ROOT, fixtures_dir, passing, run_capped

SUITE = os.path.join(ROOT, "json/test/conformance/JSON-Schema-Test-Suite/tests/draft2020-12")
# Keywords that list the members of an object, or reach a schema that may, where `.emial` is refused although an object
# may have it.
LISTS = ("properties", "patternProperties", "const", "enum", "$ref")
# Keywords that bound member names without listing them, where `.emial` is not refused although no object has it.
NAMES = ("propertyNames", "maxProperties")
# Each is typed and run on its own member of one object, so a sample one fails on still checks the others.
FILTERS = [
    ".", ".[]?", "..", "type", "length?", "keys?", "to_entries?", "[paths]", ".[0]?", "add?", "tostring",
    "if type == \"object\" then .[] else . end", "select(type == \"array\") | length", ".. | numbers",
    "[.[]?] | length", "reduce .[]? as $x (null; $x)", "map_values(.)?", "[.. | scalars] | sort",
    "{a: .}", "[., 1, \"s\"] | .[1:]", "with_entries(.)?", "map(.)?", "walk(.)", "first(.[]?)", "[last(.[]?)]",
    "add?", "join(\",\")?", "del(.[0]?)?", "[.. | strings | splits(\"a\")]", "from_entries?",
    # Computed keys, which may overwrite a constant one.
    "{a: 1, (type): 2}", "{(tostring): .}", "{a: 1} + {(type): .}",
    # Updates and paths that may be the input's own.
    ".. |= .", "(.,.) |= 1", "setpath([]; 1)", "del(.)", "delpaths([[]])", "getpath([]) |= null", "(.. | scalars) |= 1",
    # Transforms of scalars that the schema may constrain.
    "[.. | numbers | -.]", "[.. | numbers | . * 2, . - 1, . % 3?]", "[.. | strings | .[1:], ltrimstr(\"a\")]",
    "[.. | strings | ascii_downcase, ascii_upcase]", "[.. | arrays | reverse, .[1:]]", "[.. | numbers | tostring]",
    "[.. | numbers | floor, sqrt]", "[.. | strings | length]",
]
# Where `unevaluatedProperties` follows a `dependentSchemas` or a nested `oneOf`, which the typing does not trace, so
# `.emial` is not refused although no object has it.
UNTRACED = {"unevaluatedProperties.json#35", "unevaluatedProperties.json#40"}
EMIAL = [None, True, 0, 7, 10**6, -1.5, "", "x", "a@b.c", [], {}]
WORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
KEYWORDS = {"and", "or", "not", "if", "then", "elif", "else", "end", "as", "def", "reduce", "foreach", "try",
            "catch", "label", "import", "include", "__loc__", "true", "false", "null"}
REFUSAL = re.compile(r"^stury: error: (.*) at <top-level>, line 1, column (\d+):$", re.M)
# A run-time error of a value's kind, as distinct from one of its value such as a zero divisor.
KIND_ERROR = re.compile(r"Cannot index|Cannot iterate|cannot be|has no |is not a|cannot have|Cannot check")
VALUE_ERROR = re.compile(r"divisor is zero|cannot be parsed|is not valid")
ERROR = "law error"
TIMEOUT = 60
# The bytes of a fixture's instances judged: `..` and `paths` write a document's size times its depth.
INSTANCE_BYTES = 256 * 1024
# Megabytes one run may hold: the typing's budgets bound it far below.
CAP_MB = 1024


def run(argv, data=None, timeout=TIMEOUT):
    p = run_capped(argv, data, timeout, cap_mb=CAP_MB)
    return p.returncode, p.stdout, p.stderr


def suite_schemas():
    out = []
    for path in sorted(glob.glob(f"{SUITE}/*.json")):
        with open(path, "rb") as f:
            for i, group in enumerate(json.load(f)):
                out.append((f"{os.path.basename(path)}#{i}", json.dumps(group["schema"]), None))
    return out


def fixture_schemas(root):
    out = []
    for path in sorted(glob.glob(f"{root}/schema/*.schema.json")):
        data = path.replace(".schema.json", ".ndjson")
        out.append((os.path.relpath(path, root), open(path).read(), data if os.path.exists(data) else None))
    for path in sorted(glob.glob(f"{root}/jsonschema-benchmark/*/schema.json")):
        data = os.path.join(os.path.dirname(path), "instances.jsonl")
        out.append((os.path.relpath(path, root), open(path).read(), data if os.path.exists(data) else None))
    return out


def member_filters(values):
    """Reads of up to two members the first sample object has, by name."""
    first = next((v for v in values if isinstance(v, dict) and v), None)
    out = []
    for k in list(first or {})[:2]:
        if WORD.match(k) and k not in KEYWORDS:
            out += [f".{k}", f".{k}[]?", f"{{{k}}}"]
        else:
            q = json.dumps(k)
            out += [f".[{q}]", f".[{q}][]?", f"{{{q}: .[{q}]}}"]
    return out


def program(filters, tried):
    """`{"f0": [F0], ...}`, with each `F` inside `try` and its error as a value when `tried`, and where each `F` starts."""
    text, starts = "{", []
    for i, f in enumerate(filters):
        text += ", " if i else ""
        text += f'"f{i}": ['
        if tried:
            text += f'try ({f}) catch {{"{ERROR}": .}}'
        else:
            starts.append(len(text) + 1)
            text += f
        text += "]"
    return text + "}", starts


def judge(stury, case, scratch, count):
    """The law's failures on one schema, and whether `.emial` was refused, accepted or skipped."""
    name, text, instances = case
    base = os.path.join(scratch, name.replace("/", "_").replace("#", "_"))
    schema = base + ".schema.json"
    with open(schema, "w") as f:
        f.write(text)
    failures = []
    status, _, err = run([stury, "check", "--filter", ".emial", "--schema", schema, "-c"])
    if status not in (0, 1):
        return ("skipped" if status == 2 else "failed"), [] if status == 2 else [f"{name}: .emial exits {status}: {err.decode()[:300]}"]
    refused = status == 1 and b'"emial"' in err
    status, samples, _ = run([stury, "schema", "sample", schema, "--count", str(count), "--seed", "1"])
    lines = samples.splitlines() if status == 0 else []
    if instances:
        with open(instances, "rb") as f:
            held = 0
            for line in f.read().splitlines()[:count]:
                held += len(line)
                if held > INSTANCE_BYTES:
                    break
                lines.append(line)
    values = [json.loads(line) for line in lines]
    objects = [v for v in values if isinstance(v, dict)][:4]
    if objects:
        probes = [{**o, "emial": e} for o in objects for e in EMIAL]
        with open(base + ".emial.ndjson", "w") as f:
            f.write("".join(json.dumps(v) + "\n" for v in probes))
        taken = passing(stury, schema, base + ".emial.ndjson", len(probes), cap_mb=CAP_MB)
        if refused and taken and not any(word in text for word in LISTS):
            failures.append(f"{name}: .emial is refused on a schema that lists no member, and {json.dumps(probes[taken[0]])[:160]} passes it")
        if not refused and not taken and not any(word in text for word in NAMES) and name not in UNTRACED:
            failures.append(f"{name}: .emial is not refused, and no sample object with an emial member passes the schema")
    filters = FILTERS + member_filters(values)
    untried, starts = program(filters, False)
    status, _, err = run([stury, "check", "--filter", untried, "--schema", schema, "-c"])
    if status not in (0, 1):
        return "failed", failures + [f"{name}: the filters' typing exits {status}: {err.decode()[:300]}"]
    refusals = {}
    for message, column in REFUSAL.findall(err.decode(errors="replace")):
        at = max((i for i, s in enumerate(starts) if s <= int(column)), default=None)
        if at is None:
            failures.append(f"{name}: the object of the filters' outputs is refused: {message[:120]}")
        refusals.setdefault(at, message)
    tried, _ = program(filters, True)
    status, typed, err = run([stury, "check", "--filter", "{" + ", ".join(f'"f{i}": [try ({f})]' for i, f in enumerate(filters)) + "}", "--schema", schema, "-c"])
    if status not in (0, 1):
        return "failed", failures + [f"{name}: the tried filters' typing exits {status}: {err.decode()[:300]}"]
    if not lines:
        return ("refused" if refused else "accepted"), failures
    status, outputs, err = run([stury, "-c", tried], b"\n".join(lines) + b"\n")
    if status != 0:
        return "failed", failures + [f"{name}: the filters exit {status} on the samples: {err.decode()[:300]}"]
    runs = [json.loads(line) for line in outputs.splitlines()]
    for i, f in enumerate(filters):
        errors = [o for r in runs for o in r[f"f{i}"] if isinstance(o, dict) and list(o) == [ERROR]]
        kind_errors = [e[ERROR] for e in errors if isinstance(e[ERROR], str) and KIND_ERROR.search(e[ERROR]) and not VALUE_ERROR.search(e[ERROR])]
        message = refusals.get(i)
        if message is None:
            if len(runs) >= 3 and len(kind_errors) == len(runs):
                failures.append(f"{name}: {f} is accepted, and every sample fails it: {kind_errors[0][:120]}")
        elif "is not a member" in message:
            member = json.loads(message[: message.index(" is not a member")])
            if any(isinstance(v, dict) and member in v for v in values):
                failures.append(f"{name}: {f} is refused ({message[:120]}), and a sample has the member")
        elif len(errors) < len(runs):
            failures.append(f"{name}: {f} is refused ({message[:120]}), and a sample runs it")
    out_schema = base + ".out.json"
    with open(out_schema, "wb") as f:
        f.write(typed)
    kept = [{k: [o for o in v if not (isinstance(o, dict) and list(o) == [ERROR])] for k, v in r.items()} for r in runs]
    outputs_file = base + ".outputs.json"
    with open(outputs_file, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in kept))
    status, _, err = run([stury, "check", "--schema", out_schema, outputs_file])
    if status != 0:
        failures.append(f"{name}: an output fails the typed schema: {err.decode()[:400]}")
    return ("refused" if refused else "accepted"), failures


def bytes_cases(odin, scratch):
    probe = os.path.join(scratch, "types_probe")
    subprocess.run([odin, "build", "cmd/stury/test/types_probe.odin", "-file", "-o:minimal", f"-out:{probe}"], cwd=ROOT, check=True)
    schema = os.path.join(scratch, "bytes.schema.json")
    with open(schema, "w") as f:
        json.dump({"type": "object", "properties": {"photo": {"type": "string", "contentEncoding": "base64"}, "name": {"type": "string"}}, "required": ["photo", "name"]}, f)
    cases = [(".photo | type", "bytes"), (".name | type", "string"), ("type", "object")]
    failures = []
    for filter, want in cases:
        status, out, err = run([probe, schema, filter])
        got = json.loads(out) if status == 0 else None
        if got is None or got.get("const") != want:
            failures.append(f"bytes: {filter} types as {out.decode().strip()} {err.decode().strip()}, not the constant {want!r}")
    return len(cases), failures


# A schema of itself, with filters that walk it without end: each must end with the outputs unknown, not run on.
RECURSIVE = {"$defs": {"t": {"type": "object", "properties": {"c": {"type": "array", "items": {"$ref": "#/$defs/t"}}, "v": {"type": "integer"}}}}, "$ref": "#/$defs/t"}
ENDLESS = [
    "..", "recurse(.c[]?)", "def f: .c[] | f; f", "def f: (.c[] | f), .v; [f]", "[limit(3; repeat(.c))]",
    "reduce range(100) as $i (.; .c[0])", "until(.v; .c[0])", "walk(.)", "[paths]", "tostream",
    "def f(g): g | f(g | .c[]); f(.)", "[" * 600 + "." + "]" * 600,
]


def budget_cases(stury, scratch):
    schema = os.path.join(scratch, "recursive.schema.json")
    with open(schema, "w") as f:
        json.dump(RECURSIVE, f)
    failures = []
    for filter in ENDLESS:
        try:
            status, _, err = run([stury, "check", "--filter", filter, "--schema", schema], timeout=20)
        except subprocess.TimeoutExpired:
            failures.append(f"budget: {filter[:40]} did not end inside its time or memory cap")
            continue
        if status not in (0, 1):
            failures.append(f"budget: {filter[:40]} exits {status}: {err.decode()[:200]}")
    return len(ENDLESS), failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    parser.add_argument("--fixtures", help="bench/fixtures, by default the main checkout's, where it is present")
    parser.add_argument("--count", type=int, default=12)
    args = parser.parse_args()
    stury = os.path.abspath(args.binary)
    fixtures = args.fixtures or fixtures_dir()
    cases = suite_schemas()
    suite_count = len(cases)
    if os.path.isdir(fixtures):
        cases += fixture_schemas(fixtures)
    failures, counts = [], {"refused": 0, "accepted": 0, "skipped": 0, "failed": 0}
    with tempfile.TemporaryDirectory() as scratch:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            for verdict, found in pool.map(lambda c: judge(stury, c, scratch, args.count), cases):
                counts[verdict] += 1
                failures += found
        n_bytes, found = bytes_cases(args.odin, scratch)
        failures += found
        n_budget, found = budget_cases(stury, scratch)
        failures += found
    for f in failures:
        print(f)
    print(f"types law: {suite_count} suite and {len(cases) - suite_count} fixture schemas: .emial refused on {counts['refused']}, "
          f"accepted on {counts['accepted']}, {counts['skipped']} unread, {len(FILTERS)} filters and the member reads sampled on each; "
          f"{n_bytes} bytes cases, {n_budget} budget cases; {len(failures)} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
