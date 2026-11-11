#!/usr/bin/env python3
"""`stury schema gen` against the JSON Schema Test Suite's draft 2020-12 schemas and the schema fixtures: each schema's
Odin types compile, and the model compiled from them writes a schema that `stury diff --compat full --format-assert`
proves equal to the input, or gen refuses it naming a keyword. A schema that does not read is counted unread.

The model's schema of an unbounded integer holds i64's range, so a schema that is equal once those bounds are taken
off is counted apart. Where the comparison proves neither way, values sampled from both schemas, passing and failing,
are checked by both. A schema that differs, by a value one side takes and the other refuses, and one the comparison
does not prove equal are counted, not failed: their counts and the first of each are printed. A failure is a gen run that exits other than 0 or 1, a refusal that names no keyword, a type that does not
compile, or a model that does not compile or describe.

    gen_law.py BINARY [--odin PATH] [--fixtures DIR] [--batch N]
"""

import argparse
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile

from harness import ROOT, run_capped
from types_law import fixture_schemas, suite_schemas

TIMEOUT = 60
CAP_MB = 1024
# The Odin compile of one driver, which instantiates the model of every package it imports.
COMPILE_CAP_MB = 1800
COMPILE_TIMEOUT = 600
# The values sampled from each side of a comparison that proves neither way, passing and failing.
SAMPLES = 16
REFUSED = re.compile(r"^stury: error: Type is not supported: (\S+)", re.M)
# A schema that does not read, such as one whose `$ref` names a remote resource.
READ_REFUSED = re.compile(rb": Schema is refused: ")
ROOT_TYPE = re.compile(r"^(\w+) :: ", re.M)
I64 = {-(2**63), 2**63 - 1}


def run(argv, data=None, timeout=TIMEOUT, cap_mb=CAP_MB, **kw):
    p = run_capped(argv, data, timeout, cap_mb=cap_mb, **kw)
    return p.returncode, p.stdout, p.stderr


def gen(stury, case, i, scratch):
    """(verdict, detail): `generated` with the root type's name, `refused` with the keyword, or `failed`."""
    name, text, _ = case
    schema = os.path.join(scratch, f"s{i}.schema.json")
    with open(schema, "w") as f:
        f.write(text)
    status, out, err = run([stury, "schema", "gen", schema, "--package", f"g{i}"])
    if status == 1:
        m = REFUSED.search(err.decode(errors="replace"))
        return ("refused", m.group(1)) if m else ("failed", f"{name}: gen refuses naming no keyword: {err.decode()[:200]}")
    if status == 2 and READ_REFUSED.search(err):
        return "unread", None
    if status != 0:
        return "failed", f"{name}: gen exits {status}: {err.decode()[:200]}"
    pkg = os.path.join(scratch, "gen", f"g{i}")
    os.makedirs(pkg)
    with open(os.path.join(pkg, "types.odin"), "wb") as f:
        f.write(out)
    return "generated", ROOT_TYPE.search(out.decode()).group(1)


def driver(roots, scratch, batch):
    """The source of a program that writes the Load schema of each `(i, root)` model to `out/i.json`."""
    lines = [
        "package main", "", 'import "base:runtime"', 'import "core:fmt"', 'import "core:os"', 'import json "stury:json"',
        'import model "stury:core/model"', 'import schema "stury:core/schema"',
    ]
    lines += [f'import g{i} "gen:g{i}"' for i, _ in roots]
    lines += [
        "",
        "emit :: proc(register: proc(^model.Registry) -> runtime.Allocator_Error, $T: typeid, out: string) {",
        "\tdefer free_all(context.temp_allocator)",
        "\treg: model.Registry",
        "\tdefer model.registry_destroy(&reg)",
        "\tif err := register(&reg); err != nil {",
        '\t\tfmt.printfln("%s: register: %v", out, err)',
        "\t\treturn",
        "\t}",
        "\tm, err := model.compile(&reg, T, json.reads(.Json), context.temp_allocator)",
        "\tif err != nil {",
        '\t\tfmt.printfln("%s: compile: %v", out, err)',
        "\t\treturn",
        "\t}",
        "\td, derr := model.schema(&m, .Load, context.temp_allocator)",
        "\tif derr != nil {",
        '\t\tfmt.printfln("%s: schema: %v", out, derr)',
        "\t\treturn",
        "\t}",
        "\ttext, werr := schema.write(&d, json.as(.Json), {}, context.temp_allocator)",
        "\tif werr != nil {",
        '\t\tfmt.printfln("%s: write: %v", out, werr)',
        "\t\treturn",
        "\t}",
        "\t_ = os.write_entire_file(out, text)",
        "}",
        "",
        "main :: proc() {",
    ]
    out = os.path.join(scratch, "out")
    lines += [f'\temit(g{i}.register, g{i}.{root}, "{out}/{i}.json")' for i, root in roots]
    lines += ["}", ""]
    path = os.path.join(scratch, f"driver{batch}")
    os.makedirs(path)
    with open(os.path.join(path, "main.odin"), "w") as f:
        f.write("\n".join(lines))
    return path


def without_i64(node):
    """`node` with every `minimum` and `maximum` that is i64's bound taken off."""
    if isinstance(node, dict):
        return {k: without_i64(v) for k, v in node.items() if not (k in ("minimum", "maximum") and v in I64 and type(v) is int)}
    if isinstance(node, list):
        return [without_i64(v) for v in node]
    return node


def compared(stury, a, b):
    """`equal`, `differs` when a value passes one schema and fails the other, or `unproven`."""
    status, out, _ = run([stury, "diff", "--old-schema", a, "--new-schema", b, "--compat", "full", "--format-assert"])
    if status == 0:
        return "equal"
    return "differs" if re.search(rb"^(backward|forward): no,", out, re.M) else "unproven"


def judge(stury, i, scratch):
    """`equal`, `equal with i64 bounds`, `differs` or `unproven`."""
    schema, written = os.path.join(scratch, f"s{i}.schema.json"), os.path.join(scratch, "out", f"{i}.json")
    if compared(stury, schema, written) == "equal":
        return "equal"
    with open(written) as f:
        bare = without_i64(json.load(f))
    unbounded = os.path.join(scratch, "out", f"{i}.bare.json")
    with open(unbounded, "w") as f:
        json.dump(bare, f)
    verdict = compared(stury, schema, unbounded)
    if verdict == "unproven" and not agree(stury, schema, unbounded, os.path.join(scratch, "out", f"{i}.samples.ndjson")):
        return "differs"
    return "equal with i64 bounds" if verdict == "equal" else verdict


def samples(stury, schema, invalid):
    status, out, _ = run([stury, "schema", "sample", schema, "--count", str(SAMPLES), "--seed", "1"] + (["--invalid"] if invalid else []))
    return out.splitlines() if status == 0 else []


def passing(stury, schema, path, n):
    """The lines of `path`, of `n`, that pass `schema`."""
    _, _, err = run([stury, "check", "--format-assert", "--schema", schema, path])
    failed = {int(m) - 1 for m in re.findall(rf"^{re.escape(path)}:(\d+):", err.decode(errors="replace"), re.M)}
    return {i for i in range(n) if i not in failed}


def agree(stury, a, b, path):
    """Whether `a` and `b` judge alike the values each samples, passing and failing."""
    lines = [line for schema in (a, b) for invalid in (False, True) for line in samples(stury, schema, invalid)]
    with open(path, "wb") as f:
        f.write(b"".join(line + b"\n" for line in lines))
    return passing(stury, a, path, len(lines)) == passing(stury, b, path, len(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--odin", default=os.environ.get("ODIN", "odin"))
    parser.add_argument("--fixtures", help="bench/fixtures, by default the main checkout's, where it is present")
    parser.add_argument("--batch", type=int, default=120, help="packages one driver compiles")
    args = parser.parse_args()
    stury = os.path.abspath(args.binary)
    fixtures = args.fixtures
    if fixtures is None:
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        fixtures = os.path.join(os.path.dirname(os.path.abspath(os.path.join(ROOT, common))), "bench/fixtures")
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
        for b in range(0, len(roots), args.batch):
            part = roots[b : b + args.batch]
            path = driver(part, scratch, b // args.batch)
            binary = os.path.join(path, "driver")
            argv = [args.odin, "build", path, "-o:none", f"-out:{binary}", f"-collection:stury={ROOT}", f"-collection:gen={scratch}/gen"]
            status, out, err = run(argv, timeout=COMPILE_TIMEOUT, cap_mb=COMPILE_CAP_MB)
            if status != 0:
                failures.append(f"driver {b // args.batch} does not compile: {(out + err).decode()[:2000]}")
                continue
            status, out, err = run([binary])
            failures += [line for line in out.decode().splitlines()]
            if status != 0:
                failures.append(f"driver {b // args.batch} exits {status}: {err.decode()[:300]}")
        written = [(i, cases[i]) for i, _ in roots if os.path.exists(os.path.join(scratch, "out", f"{i}.json"))]
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
            for (i, case), verdict in zip(written, pool.map(lambda c: judge(stury, c[0], scratch), written)):
                counts[verdict] += 1
                firsts.setdefault(verdict, case[0])
    for f in failures:
        print(f)
    top = ", ".join(f"{k} {n}" for k, n in keywords.most_common(8))
    print(f"gen law: {suite_count} suite and {len(cases) - suite_count} fixture schemas: {counts['equal']} equal, "
          f"{counts['equal with i64 bounds']} equal with i64 bounds, {counts['refused']} refused ({top}), "
          f"{counts['differs']} differ (first {firsts.get('differs', '-')}), {counts['unproven']} unproven by the comparison "
          f"(first {firsts.get('unproven', '-')}), {counts['unread']} unread; {len(failures)} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
