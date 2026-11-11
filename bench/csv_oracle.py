#!/usr/bin/env python3
"""csv_oracle.py: the Python `jsonschema` package, the oracle for the check of CSV and TSV.

    csv_oracle.py PROBE [--seeds N] [--cases N]

PROBE is the built bench/schema_csv. Each case is a schema over a table, a text of it, and the reading options. A
converter written here, apart from the library, turns the text into the JSON a schema would judge, by the cell rule: an
empty unquoted cell is an absent member, a quoted one a string; a node that allows numbers alone reads a cell's text,
quotes cut, with the loose number grammar, one that allows booleans alone reads `true` and `false`, and any other node
reads an unquoted cell by the strict grammar when it allows a number or a boolean. A null among the kinds changes
neither reading, and an unquoted cell spelled `null` is null only when null is allowed. A node that allows a string beside
another kind, by an explicit type or an enum, takes the string reading when the other reading is invalid and the string
is valid. The kinds a node allows are its `type` narrowed by the kinds of its `const` and `enum` operands. A repeated
header column keeps its last cell, or its first under `first`, and `refuse` refuses the text, a header alone included. A
ragged row names an extra cell by its 1-based position. A text may use CRLF, start with a byte order mark, and a TSV cell
may hold the escapes `\t \n \r \0 \\`, which make it a string.

Applicators are generated so that every arm of one reads a cell alike: a cell's arms (allOf, anyOf, oneOf, not, if, a `$ref`
beside keywords) share one `type` and no operand, so one JSON value stands for the cell, read by the first arm. A row's arms
(`required` under allOf, anyOf, oneOf, not, if) read no cell. A `patternProperties` node reads its column's cells by the
pattern's node, and a container `const` or `enum` reads a column's cells by the kinds of its operands at that column.

jsonschema judges each row against the schema's `items` and the array against the rest. A case must give the same rows
as the probe: the rows that fail, with `-` for a failure no row holds. A text that breaks the table's width without
`ragged`, and a refused repeat, are held to a refusal alone, as the probe stops at them.

Run it with the pinned package: make diff-schema-csv, which is
  uv run --offline --no-project --with jsonschema==4.26.0 python3 -I bench/csv_oracle.py
Exits 1 on a difference.
"""
import argparse, json, random, re, subprocess, sys, tempfile

import jsonschema

STRICT = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")
LOOSE = re.compile(r"[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?")
EVERY = {"null", "boolean", "integer", "number", "string", "array", "object"}


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


def operand_kinds(operands):
    held = set()
    for v in operands:
        if v is None:
            held.add("null")
        elif isinstance(v, bool):
            held.add("boolean")
        elif isinstance(v, (int, float)):
            held |= {"integer", "number"}
        elif isinstance(v, str):
            held.add("string")
    return held


def allowed(node):
    """The kinds a node allows: its type narrowed by its const and enum operands."""
    if node is True or node is False:
        return set(EVERY) if node else set()
    types = node.get("type", None)
    kinds = set(EVERY) if types is None else set([types] if isinstance(types, str) else types)
    if "number" in kinds:
        kinds.add("integer")
    for key in ("const", "enum"):
        if key in node:
            kinds &= operand_kinds([node["const"]] if key == "const" else node["enum"])
    return kinds


def number(text):
    return int(text) if re.fullmatch(r"[+-]?[0-9]+", text) else float(text)


def reading(cell, quoted, kinds):
    numbers = kinds & {"integer", "number"}
    loose = kinds - {"null"}
    if not quoted and cell == "null" and "null" in kinds:
        return None
    if loose and loose <= {"integer", "number"}:
        return number(cell) if LOOSE.fullmatch(cell) else cell
    if loose == {"boolean"}:
        return True if cell == "true" else False if cell == "false" else cell
    if not quoted:
        if cell == "true" and "boolean" in kinds:
            return True
        if cell == "false" and "boolean" in kinds:
            return False
        if numbers and STRICT.fullmatch(cell):
            return number(cell)
    return cell


def read_cell(cell, quoted, node):
    """The value a node reads a cell as. With a string allowed beside the reading, by a type list or an enum, the string
    stands in when the reading is invalid and the string is valid."""
    if node is True or node is False:
        node = {}
    kinds = allowed(node)
    value = reading(cell, quoted, kinds)
    explicit = "enum" in node or "const" in node or kinds != EVERY
    if isinstance(value, str) or not explicit or "string" not in kinds or value is None:
        return value
    own = jsonschema.Draft202012Validator(node)
    if not own.is_valid(value) and own.is_valid(cell):
        return cell
    return value


def reading_node(node):
    """The node whose kinds read a cell the node judges: an applicator's first arm, whose arms share one reading."""
    if not isinstance(node, dict):
        return node
    for key in ("allOf", "anyOf", "oneOf"):
        if key in node:
            return node[key][0]
    if "not" in node:
        return node["not"]
    if "if" in node:
        return node["if"]
    return node


def column_node(items, name):
    """The node that reads column `name`'s cells: its property, the pattern it matches, the operands of a container
    `const` or `enum` at that column, else `additionalProperties`."""
    props = items.get("properties", {})
    if name in props:
        return reading_node(props[name])
    for pattern, node in items.get("patternProperties", {}).items():
        if re.search(pattern, name):
            return reading_node(node)
    if "const" in items and name in items["const"]:
        return {"const": items["const"][name]}
    if "enum" in items:
        operands = [o[name] for o in items["enum"] if name in o]
        if operands:
            return {"enum": operands}
    extra = items.get("additionalProperties", True)
    return extra if isinstance(extra, dict) else True


def instance(case, schema):
    """The rows of the case's text as JSON values, or None for a text the probe refuses without naming rows."""
    rows = table(case["text"], case["spec"])
    items = schema.get("items", {})
    if case["no_header"]:
        node = reading_node(items.get("items", {}))
        return [[None if c == "" and not q else read_cell(c, q, node) for c, q in r] for r in rows]
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
            if j < len(names) and keep[name] != j or c == "" and not q:
                continue
            row[name] = read_cell(c, q, column_node(items, name))
        out.append(row)
    return out


def expected(case):
    schema = json.loads(case["schema"])
    rows = instance(case, schema)
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
            "dups": rng.choice(["last", "first", "refuse"])}


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
    return {"schema": json.dumps(root), "text": ("\ufeff" if rng.random() < 0.1 else "") + eol.join(lines) + eol, "spec": spec, "ragged": False, "no_header": True, "dups": "last"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("probe")
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--cases", type=int, default=1500)
    args = ap.parse_args()
    differ = refused = total = 0
    for seed in range(1, args.seeds + 1):
        rng = random.Random(seed)
        cases = [(generate_headless if rng.random() < 0.1 else generate)(rng, rng.choice(["csv", "csv", "tsv"])) for _ in range(args.cases)]
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as f:
            f.write("".join(json.dumps(c) + "\n" for c in cases))
            f.flush()
            run = subprocess.run([args.probe, f.name], capture_output=True, text=True)
            if run.returncode:
                sys.exit(f"the probe stopped with {run.returncode} on seed {seed}: {run.stderr[-600:]}")
            got = run.stdout.splitlines()
        for case, mine in zip(cases, got):
            total += 1
            want = expected(case)
            if mine[0] in "UE":
                refused += 1
                print(f"seed {seed}: probe says {mine}: {case['schema']}")
                continue
            held = want == "I" or mine == "I -"
            if (want[0] != mine[0]) if held else (want != mine):
                differ += 1
                if differ <= 10:
                    print(f"seed {seed}: jsonschema {want!r}, probe {mine!r}\n  schema {case['schema']}\n  {case['spec']} dups={case['dups']} ragged={case['ragged']} no_header={case['no_header']} text {case['text']!r}")
    print(f"{total} cases, {differ} differences, {refused} refused by the probe")
    sys.exit(1 if differ or refused else 0)


main()
