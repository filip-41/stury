#!/usr/bin/env python3
"""`stury schema gen` against the JSON Schema Test Suite's draft 2020-12 schemas and the schema fixtures, once with
formats annotating and once with --format-assert: each schema's Odin types compile, and the model compiled from them
loads the values sampled from the schema, passing and failing, as `stury check` judges them, and writes a schema that
`stury diff --compat full` proves equal to the input; or gen refuses the schema naming a keyword. A schema that does
not read is counted unread.

An integer the model reads is an i64, a capacity: the schema of an unbounded integer holds i64's range, and a value
past it does not load. A schema equal to its model's once those bounds are taken off, and a value past the range that
the two judge apart, are counted as equal but for integers outside i64. Where the comparison proves neither way and
the samples agree the schema is counted unproven, and apart where the schema has no failing samples. A failure is a
gen run that exits other than 0 or 1, a refusal that names no keyword, a type that does not compile, a model that does
not compile or describe, a value the model and the check judge apart, and a comparison that finds one.

    gen_law.py BINARY [--odin PATH] [--fixtures DIR] [--batch N]
"""

import argparse
import collections
import concurrent.futures
import json
import os
import re
import sys
import tempfile

from harness import ROOT, fixtures_dir, passing, run_capped
from types_law import fixture_schemas, suite_schemas

TIMEOUT = 60
CAP_MB = 1024
# The Odin compile of one driver, which instantiates the model of every package it imports.
COMPILE_CAP_MB = 1800
COMPILE_TIMEOUT = 600
# The values sampled from each schema, passing and failing.
SAMPLES = 16
REFUSED = re.compile(r"^stury: error: Type is not supported: (\S+)", re.M)
# A schema that does not read, such as one whose `$ref` names a remote resource.
READ_REFUSED = re.compile(rb": Schema is refused: ")
ROOT_TYPE = re.compile(r"^(\w+) :: ", re.M)
I64 = {-(2**63), 2**63 - 1}
# The two runs of each schema: gen's and check's flags.
RUNS = {"a": [], "f": ["--format-assert"]}


def run(argv, data=None, timeout=TIMEOUT, cap_mb=CAP_MB, **kw):
    p = run_capped(argv, data, timeout, cap_mb=cap_mb, **kw)
    return p.returncode, p.stdout, p.stderr


def gen(stury, case, i, scratch):
    """(verdict, detail): `generated` with the runs' root types, `refused` with the keyword, `unread`, or `failed`.
    The --format-assert run is left out where its source is the annotating run's."""
    name, text, _ = case
    schema = os.path.join(scratch, f"s{i}.schema.json")
    with open(schema, "w") as f:
        f.write(text)
    sources = {}
    for tag, flags in RUNS.items():
        status, out, err = run([stury, "schema", "gen", schema, "--package", f"{tag}{i}"] + flags)
        if status == 1:
            m = REFUSED.search(err.decode(errors="replace"))
            return ("refused", m.group(1)) if m else ("failed", f"{name}: gen refuses naming no keyword: {err.decode()[:200]}")
        if status == 2 and READ_REFUSED.search(err):
            return "unread", None
        if status != 0:
            return "failed", f"{name}: gen exits {status}: {err.decode()[:200]}"
        if sources and out.replace(f"package {tag}{i}".encode(), b"") == sources["a"].replace(f"package a{i}".encode(), b""):
            break
        sources[tag] = out
    roots = {}
    for tag, out in sources.items():
        pkg = os.path.join(scratch, "gen", f"{tag}{i}")
        os.makedirs(pkg)
        with open(os.path.join(pkg, "types.odin"), "wb") as f:
            f.write(out)
        roots[tag] = ROOT_TYPE.search(out.decode()).group(1)
    samples(stury, schema, os.path.join(scratch, "out", f"{i}.ndjson"))
    return "generated", roots


def samples(stury, schema, path):
    """Writes the values sampled from `schema` to `path`, passing ones first. Where a draw of SAMPLES values finds
    one it cannot make, each seed is drawn alone."""
    lines = []
    for invalid in ([], ["--invalid"]):
        status, out, _ = run([stury, "schema", "sample", schema, "--count", str(SAMPLES), "--seed", "1"] + invalid)
        if status != 0:
            out = b"".join(run([stury, "schema", "sample", schema, "--seed", str(seed)] + invalid)[1] for seed in range(1, SAMPLES + 1))
        lines += out.splitlines()
    with open(path, "wb") as f:
        f.write(b"".join(line + b"\n" for line in lines))


DRIVER = """package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import json "stury:json"
import model "stury:core/model"
import schema "stury:core/schema"
{imports}

// Writes the Load schema of the model of `T` to `out` and, for each line of `values`, whether it loads to `verdicts`.
emit :: proc(register: proc(^model.Registry) -> runtime.Allocator_Error, $T: typeid, out, values, verdicts: string) {{
	defer free_all(context.temp_allocator)
	reg: model.Registry
	defer model.registry_destroy(&reg)
	if err := register(&reg); err != nil {{
		fmt.printfln("%s: register: %v", out, err)
		return
	}}
	m, err := model.compile(&reg, T, json.reads(.Json), context.temp_allocator)
	if err != nil {{
		fmt.printfln("%s: compile: %v", out, err)
		return
	}}
	d, derr := model.schema(&m, .Load, context.temp_allocator)
	if derr != nil {{
		fmt.printfln("%s: schema: %v", out, derr)
		return
	}}
	text, werr := schema.write(&d, json.as(.Json), {{}}, context.temp_allocator)
	if werr != nil {{
		fmt.printfln("%s: write: %v", out, werr)
		return
	}}
	_ = os.write_entire_file(out, text)
	data, _ := os.read_entire_file(values, context.temp_allocator)
	rest := string(data)
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines_iterator(&rest) {{
		v: T
		loaded := model.load(&m, transmute([]u8)line, &v, allocator = context.temp_allocator)
		strings.write_byte(&b, '1' if loaded == nil else '0')
	}}
	_ = os.write_entire_file(verdicts, strings.to_string(b))
}}

main :: proc() {{
{calls}
}}
"""


def driver(roots, scratch, batch):
    """The path of a program that writes, for each `(i, {run: root})`, each run's model's Load schema and verdicts."""
    out = os.path.join(scratch, "out")
    imports, calls = [], []
    for i, runs in roots:
        for tag, root in runs.items():
            imports.append(f'import {tag}{i} "gen:{tag}{i}"')
            calls.append(f'\temit({tag}{i}.register, {tag}{i}.{root}, "{out}/{tag}{i}.json", "{out}/{i}.ndjson", "{out}/{tag}{i}.verdicts")')
    path = os.path.join(scratch, f"driver{batch}")
    os.makedirs(path)
    with open(os.path.join(path, "main.odin"), "w") as f:
        f.write(DRIVER.format(imports="\n".join(imports), calls="\n".join(calls)))
    return path


def without_i64(node):
    """`node` with every `minimum` and `maximum` that is i64's bound taken off."""
    if isinstance(node, dict):
        return {k: without_i64(v) for k, v in node.items() if not (k in ("minimum", "maximum") and v in I64 and type(v) is int)}
    if isinstance(node, list):
        return [without_i64(v) for v in node]
    return node


def outside_i64(value):
    """Whether `value` holds an integer that no i64 holds."""
    if isinstance(value, dict):
        return any(outside_i64(v) for v in value.values())
    if isinstance(value, list):
        return any(outside_i64(v) for v in value)
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return not -(2**63) <= value < 2**63
    return isinstance(value, float) and value.is_integer() and abs(value) >= 2**63


def compared(stury, a, b, flags):
    """`equal`, `differs` when a value passes one schema and fails the other, or `unproven`."""
    status, out, _ = run([stury, "diff", "--old-schema", a, "--new-schema", b, "--compat", "full"] + flags)
    if status == 0:
        return "equal", ""
    if status == 1 and re.search(rb"^(backward|forward): no,", out, re.M):
        return "differs", out.decode(errors="replace").strip()[:300]
    if status != 1:
        return "failed", f"diff exits {status}"
    return "unproven", ""


def judge(stury, i, tag, scratch):
    """(verdict, detail) for run `tag` of schema `i`: `equal`, `equal but for integers outside i64`, `unproven`,
    `unproven, no failing samples`, `differs` or `failed`."""
    out = os.path.join(scratch, "out")
    schema, written, values = os.path.join(scratch, f"s{i}.schema.json"), os.path.join(out, f"{tag}{i}.json"), os.path.join(out, f"{i}.ndjson")
    with open(values, "rb") as f:
        lines = f.read().splitlines()
    with open(os.path.join(out, f"{tag}{i}.verdicts")) as f:
        loaded = f.read()
    if len(loaded) != len(lines):
        return "failed", f"{len(loaded)} verdicts for {len(lines)} values"
    checked = set(passing(stury, schema, values, len(lines), RUNS[tag]))
    capacity = False
    for k, line in enumerate(lines):
        if (loaded[k] == "1") != (k in checked):
            if not outside_i64(json.loads(line)):
                return "differs", f"{line.decode(errors='replace')[:160]} {'loads' if loaded[k] == '1' else 'does not load'}, and check says {'valid' if k in checked else 'invalid'}"
            capacity = True
    verdict, detail = compared(stury, schema, written, RUNS[tag])
    if verdict == "equal":
        return ("equal but for integers outside i64" if capacity else "equal"), ""
    with open(written) as f:
        bare = without_i64(json.load(f))
    unbounded = os.path.join(out, f"{tag}{i}.bare.json")
    with open(unbounded, "w") as f:
        json.dump(bare, f)
    verdict, detail = compared(stury, schema, unbounded, RUNS[tag])
    if verdict == "equal":
        return "equal but for integers outside i64", ""
    if verdict != "unproven":
        return verdict, detail
    failing = sum(1 for k in range(len(lines)) if k not in checked)
    return ("unproven" if failing > 0 else "unproven, no failing samples"), ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    parser.add_argument("--fixtures", help="bench/fixtures, by default the main checkout's, where it is present")
    parser.add_argument("--batch", type=int, default=120, help="packages one driver compiles")
    args = parser.parse_args()
    stury = os.path.abspath(args.binary)
    fixtures = args.fixtures or fixtures_dir()
    cases = suite_schemas()
    suite_count = len(cases)
    if os.path.isdir(fixtures):
        cases += fixture_schemas(fixtures)
    failures, counts, keywords, firsts = [], collections.Counter(), collections.Counter(), {}
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.path.join(ROOT, "build"), prefix="gen_law.") as scratch:
        os.makedirs(os.path.join(scratch, "gen"))
        os.makedirs(os.path.join(scratch, "out"))
        roots = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            for i, (verdict, detail) in enumerate(pool.map(lambda c: gen(stury, c[1], c[0], scratch), enumerate(cases))):
                if verdict == "generated":
                    roots.append((i, detail))
                elif verdict == "refused":
                    counts["refused"] += 1
                    keywords[detail] += 1
                elif verdict == "unread":
                    counts["unread"] += 1
                else:
                    failures.append(detail)
        batches, part, packages = [], [], 0
        for r in roots:
            if part and packages + len(r[1]) > args.batch:
                batches.append(part)
                part, packages = [], 0
            part.append(r)
            packages += len(r[1])
        batches += [part] if part else []
        for batch, part in enumerate(batches):
            path = driver(part, scratch, batch)
            binary = os.path.join(path, "driver")
            argv = [args.odin, "build", path, "-o:none", f"-out:{binary}", f"-collection:stury={ROOT}", f"-collection:gen={scratch}/gen"]
            status, out, err = run(argv, timeout=COMPILE_TIMEOUT, cap_mb=COMPILE_CAP_MB)
            if status != 0:
                failures.append(f"driver {batch} does not compile: {(out + err).decode()[:2000]}")
                continue
            status, out, err = run([binary])
            failures += [line for line in out.decode().splitlines()]
            if status != 0:
                failures.append(f"driver {batch} exits {status}: {err.decode()[:300]}")
        judged = [(i, tag) for i, runs in roots for tag in runs if os.path.exists(os.path.join(scratch, "out", f"{tag}{i}.verdicts"))]
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            for (i, tag), (verdict, detail) in zip(judged, pool.map(lambda c: judge(stury, c[0], c[1], scratch), judged)):
                name = f"{cases[i][0]}{' --format-assert' if tag == 'f' else ''}"
                counts[verdict] += 1
                firsts.setdefault(verdict, name)
                if verdict in ("differs", "failed"):
                    failures.append(f"{name}: {verdict}: {detail}")
    for f in failures:
        print(f)
    top = ", ".join(f"{k} {n}" for k, n in keywords.most_common(8))
    print(f"gen law: {suite_count} suite and {len(cases) - suite_count} fixture schemas, {len(roots)} generated "
          f"in {len(judged)} runs (formats annotating, and asserting where that changes the types): "
          f"{counts['equal']} equal, {counts['equal but for integers outside i64']} equal but for integers outside i64, "
          f"{counts['unproven']} unproven by the comparison with samples agreeing (first {firsts.get('unproven', '-')}), "
          f"{counts['unproven, no failing samples']} unproven with no failing samples (first {firsts.get('unproven, no failing samples', '-')}), "
          f"{counts['differs']} differ; {counts['refused']} schemas refused ({top}), {counts['unread']} unread; {len(failures)} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
