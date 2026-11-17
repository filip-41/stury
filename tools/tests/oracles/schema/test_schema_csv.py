r"""The check of CSV and TSV against jsonschema over a converter written here, apart from the library, that turns a table
into the JSON a schema judges: an empty unquoted cell is null, any other cell a string, and under `infer` an unquoted cell
that is exactly a JSON number, `true` or `false` is that value. A repeated header column keeps its last cell, or its first
under `first`, and `refuse` refuses the text, a header alone included. A ragged row names an extra cell by its 1-based
position. A text may use CRLF, start with a byte order mark, and a TSV cell may hold the escapes `\t \n \r \0 \\`,
which make it a string.

jsonschema judges each row against the schema's `items` and the array against the rest. A case must give the same rows
as the probe: the rows that fail, with `-` for a failure no row holds. A text that breaks the table's width without
`ragged`, and a refused repeat, are held to a refusal alone, as the probe stops at them.
"""

import json
import os
import random
import re
import subprocess

import jsonschema
import pytest

from capped import ROOT

DEFAULT_SEEDS = [1, 2, 3]
CASES = 1500

STRICT = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")


TSV_ESCAPES = {"t": "\t", "n": "\n", "r": "\r", "0": "\0", "\\": "\\"}


def table(text, spec):
    """The records of `text` as (cell, quoted) pairs. Empty lines are no record. A TSV cell with an escape is marked quoted,
    as it is no exact spelling."""
    text = text.removeprefix("\ufeff")
    delim = "\t" if spec == "tsv" else ","

    def eol(i):
        return 1 if text[i] == "\n" else 2 if text.startswith("\r\n", i) else 0

    rows, row, i = [], [], 0
    while i < len(text):
        if eol(i):
            if row or i > 0 and text[i - 1] != "\n":
                rows.append(row)
            row, i = [], i + eol(i)
            continue
        cell, quoted = "", False
        if spec == "csv" and text[i] == '"':
            quoted, i = True, i + 1
            while True:
                if text[i] == '"' and text[i + 1:i + 2] == '"':
                    cell, i = cell + '"', i + 2
                elif text[i] == '"':
                    i += 1
                    break
                else:
                    cell, i = cell + text[i], i + 1
        else:
            while i < len(text) and text[i] != delim and not eol(i):
                if spec == "tsv" and text[i] == "\\":
                    cell, quoted, i = cell + TSV_ESCAPES[text[i + 1]], True, i + 2
                else:
                    cell, i = cell + text[i], i + 1
        row.append((cell, quoted))
        if i < len(text) and text[i] == delim:
            i += 1
            if i == len(text) or eol(i):
                row.append(("", False))
    if row:
        rows.append(row)
    return [r for r in rows if r]


def reading(cell, quoted, infer):
    """The JSON a cell is judged as: null for an empty unquoted cell, a string, or under `infer` the number, true or false an
    unquoted cell spells exactly."""
    if cell == "" and not quoted:
        return None
    if infer and not quoted:
        if cell in ("true", "false"):
            return cell == "true"
        if STRICT.fullmatch(cell):
            return int(cell) if re.fullmatch(r"-?[0-9]+", cell) else float(cell)
    return cell


def instance(case):
    """The rows of the case's text as JSON values, or None for a text the probe refuses without naming rows."""
    rows = table(case["text"], case["spec"])
    infer = case["infer"]
    if case["no_header"]:
        return [[reading(c, q, infer) for c, q in r] for r in rows]
    if not rows:
        return []
    names = [c for c, _ in rows[0]]
    if len(set(names)) != len(names) and case["dups"] == "refuse":
        return None
    keep = {}
    for j, name in enumerate(names):
        if name not in keep or case["dups"] != "first":
            keep[name] = j
    out = []
    for r in rows[1:]:
        if len(r) != len(names) and not case["ragged"]:
            return None
        row = {}
        for j, (c, q) in enumerate(r):
            name = names[j] if j < len(names) else str(j + 1)
            if j < len(names) and keep[name] != j:
                continue
            row[name] = reading(c, q, infer)
        out.append(row)
    return out


def expected(case):
    schema = json.loads(case["schema"])
    rows = instance(case)
    if rows is None:
        return "I"
    validator = jsonschema.Draft202012Validator
    own = validator({"$defs": schema.get("$defs", {}), **schema.get("items", {})})
    rest = validator({k: v for k, v in schema.items() if k != "items"})
    bad = sorted(i for i, r in enumerate(rows) if not own.is_valid(r))
    if not rest.is_valid(rows):
        bad = [-1] + bad
    return "V" if not bad else "I " + ",".join("-" if i < 0 else str(i) for i in bad)


NUMBERS = ["0", "1", "2", "3", "5", "-1", "+5", "007", "5.", "5.0", ".5", "1e2", "1E+2", "2.5", "-0", "10", "1_0", "0x1"]
WORDS = ["true", "false", "True", "x", "ab", "abcd", "null", "a b"]
PROPERTIES = [
    {"type": "integer"}, {"type": "integer", "minimum": 1}, {"type": "integer", "maximum": 5}, {"type": "number", "minimum": 0},
    {"type": "number", "multipleOf": 0.5}, {"type": "string"}, {"type": "string", "maxLength": 2}, {"type": "string", "minLength": 2},
    {"type": "string", "pattern": "^[a-z]+$"}, {"type": "boolean"}, {"type": ["integer", "string"]}, {"type": ["integer", "string"], "maxLength": 1},
    {"type": ["number", "boolean"]}, {"type": ["boolean", "string"], "maxLength": 3}, {"enum": [1, 2, 3]}, {"enum": ["1", "2"]},
    {"enum": [True, "x"]}, {"const": 5}, {"const": "5"}, {"const": True}, {}, {"minimum": 3}, {"maxLength": 2}, {"type": "null"},
    {"type": "integer", "exclusiveMinimum": 0}, {"enum": [1, "1", 2.5]},
    {"type": ["integer", "null"]}, {"type": ["boolean", "null"]}, {"type": ["string", "null"], "maxLength": 2},
    {"type": ["number", "null"], "minimum": 1}, {"enum": [None, 1]}, {"enum": [None, True]}, {"enum": [None, "x"]},
    {"enum": ["1", 2]}, {"const": None}, {"type": ["integer", "string"], "minimum": 6}, {"type": ["number", "string"], "maximum": 2},
    {"type": ["integer", "boolean", "null"]},
]
ESCAPES = ["a\\tb", "\\n", "5\\0", "\\\\", "x\\r"]


GROUPS = {
    "integer": [{"minimum": 1}, {"maximum": 5}, {"exclusiveMinimum": 0}, {"multipleOf": 2}, {}],
    "number": [{"minimum": 0}, {"maximum": 2.5}, {"multipleOf": 0.5}, {}],
    "string": [{"maxLength": 2}, {"minLength": 2}, {"pattern": "^[a-z]+$"}, {}],
    "boolean": [{}],
}


def cell_arms(rng, n=2):
    kind = rng.choice(sorted(GROUPS))
    return [{"type": kind, **rng.choice(GROUPS[kind])} for _ in range(n)]


def cell_node(rng, defs):
    """A node of a cell judged by arms that read it alike."""
    arms = cell_arms(rng, 3)
    form = rng.choice(["allOf", "anyOf", "oneOf", "not", "if", "ref"])
    if form == "not":
        return {"not": arms[0]}
    if form == "if":
        node = {"if": arms[0], "then": arms[1]}
        if rng.random() < 0.6:
            node["else"] = arms[2]
        return node
    if form == "ref":
        name = "d%d" % len(defs)
        defs[name] = arms[0]
        return {"$ref": "#/$defs/" + name, "type": arms[1]["type"], **{k: v for k, v in arms[1].items() if k != "type"}}
    return {form: arms[: rng.randint(1, 3)]}


def row_arms(rng, columns):
    """A row's arms, which read no cell: they ask which members the row has."""
    names = sorted(set(columns) | {"z"})
    def need():
        return {"required": sorted(rng.sample(names, rng.randint(1, min(2, len(names)))))}
    form = rng.choice(["allOf", "anyOf", "oneOf", "not", "if", "dependentRequired", "dependentSchemas"])
    if form == "not":
        return {"not": need()}
    if form == "if":
        node = {"if": need(), "then": need()}
        if rng.random() < 0.6:
            node["else"] = need()
        return node
    if form == "dependentRequired":
        return {"dependentRequired": {rng.choice(names): need()["required"]}}
    if form == "dependentSchemas":
        return {"dependentSchemas": {rng.choice(names): need()}}
    return {form: [need() for _ in range(rng.randint(1, 3))]}


POOLS = [[1, 2, 5, 2.5], ["x", "5"], [True, False], [None]]


def operand_row(rng, columns, kinds):
    """An object whose value at each column is of the kind `kinds` fixes for it, so that the operands of one enum read a
    column's cell alike."""
    row = {}
    for c in sorted(set(columns)):
        if rng.random() >= 0.2:
            row[c] = rng.choice(kinds[c])
    return row


def generate(rng, spec):
    columns = [rng.choice("abcd") for _ in range(rng.randint(1, 4))]
    if rng.random() < 0.7:
        columns = list(dict.fromkeys(columns))
    mode = rng.choice(["properties"] * 5 + ["cells", "cells", "rows", "rows", "patterns", "patterns", "const", "enum"])
    defs = {}
    props = {c: rng.choice(PROPERTIES) for c in set(columns)}
    row = {"properties": props}
    if mode == "cells":
        props = {c: cell_node(rng, defs) if rng.random() < 0.7 else rng.choice(PROPERTIES) for c in set(columns)}
        row = {"properties": props}
    elif mode == "rows":
        row.update(row_arms(rng, columns))
    elif mode == "patterns":
        letters = rng.sample("abcd", rng.randint(1, 2))
        patterns = {rng.choice(["^%s$", "^%s"]) % l: rng.choice([cell_node(rng, defs), rng.choice(PROPERTIES)]) for l in letters}
        row = {"properties": {c: p for c, p in props.items() if c not in letters}, "patternProperties": patterns}
    elif mode == "const":
        row = {"const": operand_row(rng, columns, {c: rng.choice(POOLS) for c in set(columns)})}
    elif mode == "enum":
        kinds = {c: rng.choice(POOLS) for c in set(columns)}
        row = {"enum": [operand_row(rng, columns, kinds) for _ in range(rng.randint(2, 3))]}
    if mode in ("properties", "cells", "rows", "patterns") and rng.random() < 0.4:
        row["required"] = sorted(rng.sample(sorted(set(columns)), rng.randint(1, len(set(columns)))))
    extra = rng.choice([None, None, False, {"type": "string"}, {"type": "integer"}])
    if extra is not None and mode in ("properties", "cells", "rows", "patterns"):
        row["additionalProperties"] = extra
    if mode in ("properties", "cells", "rows", "patterns") and rng.random() < 0.2:
        row["minProperties"] = rng.randint(1, 3)
    if mode in ("properties", "cells", "rows", "patterns") and rng.random() < 0.2:
        row["maxProperties"] = rng.randint(1, 3)
    root = {"type": "array", "items": row}
    if defs:
        root["$defs"] = defs
    if rng.random() < 0.15:
        root["minItems"] = rng.randint(1, 3)
    if rng.random() < 0.1:
        root["allOf"] = [{"minItems": rng.randint(1, 3)}, {"maxItems": rng.randint(2, 4)}]
    if rng.random() < 0.05:
        root["anyOf"] = [{"minItems": 2}, {"maxItems": 1}]
    def cell():
        r = rng.random()
        if r < 0.15:
            return ""
        text = rng.choice(NUMBERS) if r < 0.6 else rng.choice(WORDS) if r < 0.85 else str(rng.randint(-3, 12))
        if spec == "tsv" and rng.random() < 0.1:
            return rng.choice(ESCAPES)
        if spec == "csv" and rng.random() < 0.18:
            return '"' + text.replace('"', '""') + '"'
        return text
    ragged = rng.random() < 0.25
    delim = "\t" if spec == "tsv" else ","
    width = len(columns)
    lines = [delim.join(columns)]
    for _ in range(rng.randint(0, 4)):
        n = width if not ragged or rng.random() < 0.6 else rng.randint(1, width + 2)
        cells = [cell() for _ in range(n)]
        if n == 1 and cells[0] == "":
            cells[0] = "x"
        lines.append(delim.join(cells))
    eol = "\r\n" if rng.random() < 0.2 else "\n"
    text = ("\ufeff" if rng.random() < 0.1 else "") + eol.join(lines) + (eol if rng.random() < 0.8 else "")
    return {"schema": json.dumps(root), "text": text, "spec": spec, "ragged": ragged, "no_header": False,
            "infer": rng.random() < 0.5, "dups": rng.choice(["last", "first", "refuse"])}


def generate_headless(rng, spec):
    defs = {}
    leaf = cell_node(rng, defs) if rng.random() < 0.4 else rng.choice(PROPERTIES)
    root = {"type": "array", "items": {"type": "array", "items": leaf}}
    if defs:
        root["$defs"] = defs
    delim = "\t" if spec == "tsv" else ","
    width = rng.randint(1, 3)
    lines = []
    for _ in range(rng.randint(1, 4)):
        cells = [rng.choice(NUMBERS + WORDS + [""]) for _ in range(width)]
        if width == 1 and cells[0] == "":
            cells[0] = "x"
        lines.append(delim.join(cells))
    eol = "\r\n" if rng.random() < 0.2 else "\n"
    return {"schema": json.dumps(root), "text": ("\ufeff" if rng.random() < 0.1 else "") + eol.join(lines) + eol, "spec": spec, "ragged": False, "no_header": True, "infer": rng.random() < 0.5, "dups": "last"}


@pytest.fixture(scope="module")
def probe(odin, tmp_path_factory):
    binary = str(tmp_path_factory.mktemp("schema_csv") / "probe")
    subprocess.run([odin, "build", os.path.join(os.path.dirname(__file__), "csv"), "-o:minimal", f"-out:{binary}"], cwd=ROOT, check=True)
    return binary


def test_check_gives_jsonschema_verdicts_on_tables(probe, seed, request, tmp_path):
    rng = random.Random(seed)
    cases = [(generate_headless if rng.random() < 0.1 else generate)(rng, rng.choice(["csv", "csv", "tsv"]))
             for _ in range(request.config.getoption("--cases") or CASES)]
    path = tmp_path / "cases.jsonl"
    path.write_text("".join(json.dumps(c) + "\n" for c in cases))
    run = subprocess.run([probe, str(path)], capture_output=True, text=True)
    assert run.returncode == 0, f"the probe stopped with {run.returncode}: {run.stderr[-600:]}"
    answers = run.stdout.splitlines()
    assert len(answers) == len(cases), f"the probe answered {len(answers)} of {len(cases)} cases"
    bad = []
    for case, mine in zip(cases, answers):
        want = expected(case)
        if mine[0] in "UE":
            bad.append(f"probe says {mine}: {case['schema']}")
            continue
        held = want == "I" or mine == "I -"
        if (want[0] != mine[0]) if held else (want != mine):
            bad.append(f"jsonschema {want!r}, probe {mine!r}\n  schema {case['schema']}\n  {case['spec']} dups={case['dups']} "
                       f"ragged={case['ragged']} no_header={case['no_header']} infer={case['infer']} text {case['text']!r}")
    assert not bad, f"{len(bad)} of {len(cases)} cases differ:\n" + "\n".join(bad[:10])
