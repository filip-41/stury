#!/usr/bin/env python3
"""v1-vs-v2 Differential Oracle Runner for stury (`next/`).

Builds a self-contained v2 probe in a temporary directory and compares:
  1. `validate` verdicts (valid vs invalid)
  2. Canonical `build -> write` JSON output
  3. `jq` query outputs

against v1 (`build/stury`, `build/stury-minimal`, or an on-the-fly `-o:minimal` build of `cmd/stury`)
across deterministic randomized + corpus inputs for JSON, TOML, XML, CSV, CBOR, YAML, and HTML,
plus self-check + round-trip + jq parity for MessagePack (which v1 does not implement).
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import random
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any

NEXT_DIR = pathlib.Path(__file__).resolve().parent.parent
REPO_DIR = NEXT_DIR.parent

V2_PROBE_SOURCE = r'''package main

import "core:fmt"
import "core:os"
import "stury:json"
import "stury:msgpack"
import "stury:stury"

emit_jq :: proc(_: rawptr, b: []u8) -> bool {
	_, _ = os.write(os.stdout, b)
	_, _ = os.write_string(os.stdout, "\n")
	return true
}

run :: proc() -> int {
	if len(os.args) < 3 {
		fmt.eprintln("usage: v2probe <validate|canon|roundtrip|jq> <format> [filter]")
		return 2
	}
	mode := os.args[1]
	fmt_name := os.args[2]
	entry, ok := stury.format_by_name(fmt_name)
	if !ok {
		fmt.eprintfln("unknown format: %s", fmt_name)
		return 2
	}
	src, rerr := os.read_entire_file_from_file(os.stdin, context.allocator)
	if rerr != nil {
		fmt.eprintfln("stdin read error: %v", rerr)
		return 2
	}
	defer delete(src)

	switch mode {
	case "validate":
		if err := stury.validate(src, entry.spec); err != nil {
			return 5
		}
		return 0
	case "canon":
		out, _, err := stury.format(src, entry.spec, json.Spec.Json)
		if err != nil {
			return 5
		}
		defer delete(out)
		_, _ = os.write(os.stdout, out)
		_, _ = os.write_string(os.stdout, "\n")
		return 0
	case "roundtrip":
		doc, berr := stury.build(src, entry.spec)
		if berr != nil {
			return 5
		}
		defer stury.destroy(&doc)
		rt, _, werr := stury.write(&doc, entry.spec)
		if werr != nil {
			return 5
		}
		defer delete(rt)
		if entry.family == .Msgpack {
			compact, _, cwerr := stury.write(&doc, msgpack.Spec.Compact)
			if cwerr != nil {
				return 5
			}
			defer delete(compact)
			if verr := stury.validate(compact, msgpack.Spec.Compact); verr != nil {
				return 5
			}
		}
		out, _, ferr := stury.format(rt, entry.spec, json.Spec.Json)
		if ferr != nil {
			return 5
		}
		defer delete(out)
		_, _ = os.write(os.stdout, out)
		_, _ = os.write_string(os.stdout, "\n")
		return 0
	case "jq":
		if len(os.args) < 4 {
			fmt.eprintln("missing jq filter")
			return 2
		}
		prog, errs := stury.jq_compile(os.args[3])
		if len(errs) > 0 {
			return 3
		}
		defer stury.jq_destroy(prog)
		res := stury.jq_run(prog, src, entry.spec, emit_jq)
		defer stury.jq_run_result_destroy(&res)
		if res.err != .None {
			return 5
		}
		return 0
	case:
		fmt.eprintfln("unknown mode: %s", mode)
		return 2
	}
}

main :: proc() {
	os.exit(run())
}
'''


def encode_cbor_head(major: int, val: int) -> bytes:
    prefix = major << 5
    if val < 24:
        return bytes([prefix | val])
    if val < 256:
        return bytes([prefix | 24, val])
    if val < 65536:
        return bytes([prefix | 25]) + struct.pack(">H", val)
    return bytes([prefix | 26]) + struct.pack(">I", val)


def encode_cbor(obj) -> bytes:
    if obj is None:
        return b"\xf6"
    if isinstance(obj, bool):
        return b"\xf5" if obj else b"\xf4"
    if isinstance(obj, int):
        if obj >= 0:
            return encode_cbor_head(0, obj)
        return encode_cbor_head(1, -1 - obj)
    if isinstance(obj, str):
        raw = obj.encode("utf-8")
        return encode_cbor_head(3, len(raw)) + raw
    if isinstance(obj, list):
        return encode_cbor_head(4, len(obj)) + b"".join(encode_cbor(x) for x in obj)
    if isinstance(obj, dict):
        return encode_cbor_head(5, len(obj)) + b"".join(
            encode_cbor(k) + encode_cbor(v) for k, v in obj.items()
        )
    raise TypeError(type(obj))


def encode_msgpack(obj) -> bytes:
    if obj is None:
        return b"\xc0"
    if isinstance(obj, bool):
        return b"\xc3" if obj else b"\xc2"
    if isinstance(obj, int):
        if 0 <= obj <= 0x7F:
            return bytes([obj])
        if -32 <= obj < 0:
            return bytes([obj & 0xFF])
        if 0 <= obj <= 0xFF:
            return b"\xcc" + bytes([obj])
        if 0 <= obj <= 0xFFFF:
            return b"\xcd" + struct.pack(">H", obj)
        if 0 <= obj <= 0xFFFFFFFF:
            return b"\xce" + struct.pack(">I", obj)
        if -128 <= obj < 0:
            return b"\xd0" + struct.pack(">b", obj)
        if -32768 <= obj < 0:
            return b"\xd1" + struct.pack(">h", obj)
        return b"\xd2" + struct.pack(">i", obj)
    if isinstance(obj, str):
        raw = obj.encode("utf-8")
        n = len(raw)
        if n < 32:
            return bytes([0xA0 | n]) + raw
        if n < 256:
            return b"\xd9" + bytes([n]) + raw
        return b"\xda" + struct.pack(">H", n) + raw
    if isinstance(obj, list):
        n = len(obj)
        head = bytes([0x90 | n]) if n < 16 else b"\xdc" + struct.pack(">H", n)
        return head + b"".join(encode_msgpack(x) for x in obj)
    if isinstance(obj, dict):
        n = len(obj)
        head = bytes([0x80 | n]) if n < 16 else b"\xde" + struct.pack(">H", n)
        return head + b"".join(encode_msgpack(k) + encode_msgpack(v) for k, v in obj.items())
    raise TypeError(type(obj))


@dataclass
class Case:
    fmt: str
    name: str
    data: bytes
    expect_valid: bool | None = None
    jq_filters: tuple[str, ...] = ()
    self_check: bool = False
    expect_obj: Any = None


def build_v2_probe(odin: str, tmpdir: pathlib.Path) -> pathlib.Path:
    src_dir = tmpdir / "v2probe_src"
    src_dir.mkdir(parents=True, exist_ok=True)
    (src_dir / "main.odin").write_text(V2_PROBE_SOURCE, encoding="utf-8")
    exe = ".exe" if sys.platform == "win32" else ""
    out_bin = tmpdir / f"v2probe{exe}"
    cmd = [
        odin,
        "build",
        str(src_dir),
        f"-collection:stury={NEXT_DIR}",
        "-o:minimal",
        f"-out:{out_bin}",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"failed to build v2 probe:\n{res.stdout}\n{res.stderr}")
    return out_bin


def locate_or_build_v1(odin: str, v1_arg: str | None, tmpdir: pathlib.Path) -> pathlib.Path:
    exe = ".exe" if sys.platform == "win32" else ""
    if v1_arg:
        p = pathlib.Path(v1_arg).resolve()
        if not p.is_file():
            raise FileNotFoundError(f"v1 binary not found: {p}")
        return p
    candidates = [REPO_DIR / "build" / f"stury{exe}", REPO_DIR / "build" / f"stury-minimal{exe}"]
    try:
        common = subprocess.check_output(
            ["git", "rev-parse", "--git-common-dir"], cwd=REPO_DIR, text=True
        ).strip()
        common_root = (REPO_DIR / common).resolve().parent
        candidates.extend([common_root / "build" / f"stury{exe}", common_root / "build" / f"stury-minimal{exe}"])
    except Exception:
        pass
    for cand in candidates:
        if cand.is_file():
            return cand
    out_bin = tmpdir / f"stury-v1{exe}"
    cmd = [
        odin,
        "build",
        str(REPO_DIR / "cmd" / "stury"),
        "-o:minimal",
        "-define:STURY_VERSION=\"oracle\"",
        f"-out:{out_bin}",
    ]
    if sys.platform == "darwin":
        sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
        cmd.append(
            f"-extra-linker-flags:-L{sdk}/usr/lib/system -lsystem_m -lsystem_c "
            f"-lsystem_kernel -lsystem_pthread -lsystem_malloc -Wl,-dead_strip_dylibs"
        )
    res = subprocess.run(cmd, cwd=REPO_DIR, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"failed to build v1 CLI:\n{res.stdout}\n{res.stderr}")
    return out_bin


def generate_cases(seed: int, rounds: int) -> list[Case]:
    rng = random.Random(seed)
    keys = ["alpha", "beta", "gamma", "delta", "id", "name", "ok", "score"]
    strs = ["ada", "stury", "hello world", "a-b_c", "42", ""]

    def rand_val(depth: int, allow_null: bool = True):
        if depth <= 0:
            choices = [
                lambda: rng.randint(-500, 500),
                lambda: rng.choice([True, False]),
                lambda: rng.choice(strs),
            ]
            if allow_null:
                choices.append(lambda: None)
            return rng.choice(choices)()
        kind = rng.randint(0, 4)
        if kind == 0:
            return [rand_val(depth - 1, allow_null) for _ in range(rng.randint(0, 4))]
        if kind == 1:
            n = rng.randint(1, 4)
            chosen = rng.sample(keys, n)
            return {k: rand_val(depth - 1, allow_null) for k in chosen}
        return rand_val(0, allow_null)

    cases: list[Case] = []

    # Corpus + edge cases
    cases.extend([
        Case("json", "corpus_empty_obj", b"{}", True, (".", "keys")),
        Case("json", "corpus_nested", b'{"u":{"name":"ada","nums":[1,2,3]},"ok":true}', True, (".u.name", ".u.nums | add", "keys")),
        Case("json", "corpus_unicode_escape", rb'{"s":"a\nb\t\"c\\d"}', True, (".s",)),
        Case("json", "corpus_invalid_trailing_comma", b'{"a":1,}', False),
        Case("json", "corpus_invalid_leading_zero", b'{"a":01}', False),
        Case("json", "corpus_invalid_unclosed", b'{"a":[1,2}', False),
        Case("toml", "corpus_table", b'[user]\nname = "ada"\nid = 7\ntags = ["a", "b"]\n', True, (".user.name", ".user.id", ".user.tags | length")),
        Case("toml", "corpus_invalid_dup_key", b"a = 1\na = 2\n", False),
        Case("xml", "corpus_simple", b"<root><a>hello</a><b>42</b></root>", True, (".root.a", ".root.b")),
        Case("xml", "corpus_invalid_mismatch", b"<root><a>1</b></root>", False),
        Case("csv", "corpus_table", b"id,name,score\n1,ada,99\n2,grace,100\n", True, (".[0].name", ".[1].score", "length", "map(.name)")),
        Case("csv", "corpus_quoted", b'id,note\n1,"hello, world"\n2,"a""b"\n', True, (".[0].note", ".[1].note")),
        Case("csv", "corpus_invalid_quote", b'id,note\n1,"unterminated\n', False),
        Case("cbor", "corpus_map", encode_cbor({"a": 1, "b": ["x", True, None]}), True, (".a", ".b[0]", ".b | length")),
        Case("cbor", "corpus_invalid_trunc", b"\xa2\x61a\x01\x61b", False),
        Case("yaml", "corpus_map", b"user:\n  name: ada\n  nums:\n    - 1\n    - 2\n    - 3\nok: true\n", True, (".user.name", ".user.nums | add", ".ok")),
        Case("yaml", "corpus_flow", b'{a: [1, 2], b: "hello"}\n', True, (".a | length", ".b")),
        Case("yaml", "corpus_invalid_flow", b"a: [1, 2\n", False),
        Case("html", "corpus_doc", b"<!DOCTYPE html><html><head><title>t</title></head><body><div><p>hello</p><span>42</span></div></body></html>", True, (".html.head.title", ".html.body.div.p", ".html.body.div.span")),
        Case("html", "corpus_invalid_no_doctype", b"<div><p>hello</p></div>", False),
        Case("html", "corpus_invalid_eof_tag", b'<!DOCTYPE html><html><body><div id="a"', False),
        Case("msgpack", "corpus_map", encode_msgpack({"a": 1, "b": ["x", True, None]}), True, (".a", ".b[0]", ".b | length"), True, {"a": 1, "b": ["x", True, None]}),
        Case("msgpack", "corpus_invalid_never_used", b"\xc1", False, (), True),
        Case("msgpack", "corpus_invalid_trunc", b"\x82\xa1a\x01\xa1b", False, (), True),
    ])

    # Randomized cases across all 8 formats
    for i in range(rounds):
        obj = {
            "id": rng.randint(1, 9999),
            "name": rng.choice(strs),
            "flag": rng.choice([True, False]),
            "items": [rand_val(1, True) for _ in range(rng.randint(1, 4))],
            "nested": {"x": rng.randint(-100, 100), "y": rng.choice(strs)},
        }
        jbytes = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        cases.append(Case("json", f"rand_json_{i}", jbytes, True, (".id", ".nested.x", ".items | length", "keys | sort")))

        # Corrupted JSON
        if len(jbytes) > 4:
            cut = rng.randint(1, len(jbytes) - 2)
            cases.append(Case("json", f"rand_json_trunc_{i}", jbytes[:cut], False))

        # CBOR from same random object
        cbytes = encode_cbor(obj)
        cases.append(Case("cbor", f"rand_cbor_{i}", cbytes, True, (".id", ".nested.x", ".items | length")))

        # MessagePack from same random object (v2 self-check + round-trip + jq parity)
        mpbytes = encode_msgpack(obj)
        cases.append(Case("msgpack", f"rand_msgpack_{i}", mpbytes, True, (".id", ".nested.x", ".items | length", "keys | sort"), True, obj))
        if len(mpbytes) > 3:
            mp_cut = rng.randint(1, len(mpbytes) - 1)
            cases.append(Case("msgpack", f"rand_msgpack_trunc_{i}", mpbytes[:mp_cut], False, (), True))

        # TOML
        toml_str = (
            f'id = {rng.randint(0, 999)}\n'
            f'name = "{rng.choice(strs)}"\n'
            f'ok = {"true" if rng.choice([True, False]) else "false"}\n'
            f'nums = [{rng.randint(-50, 50)}, {rng.randint(-50, 50)}]\n'
            f'\n[nested]\n'
            f'score = {rng.randint(0, 500)}\n'
        )
        cases.append(Case("toml", f"rand_toml_{i}", toml_str.encode("utf-8"), True, (".id", ".nested.score", ".nums | add")))

        # XML
        xml_str = (
            f"<root>"
            f"<id>{rng.randint(1, 999)}</id>"
            f"<name>{rng.choice(['ada', 'grace', 'alan', 'barbara'])}</name>"
            f"<nested><score>{rng.randint(0, 500)}</score></nested>"
            f"</root>"
        )
        cases.append(Case("xml", f"rand_xml_{i}", xml_str.encode("utf-8"), True, (".root.id", ".root.nested.score")))

        # CSV
        rows = [f"id,name,score"]
        n_rows = rng.randint(1, 5)
        for r in range(n_rows):
            rows.append(f"{r + 1},{rng.choice(['ada', 'grace', 'alan'])},{rng.randint(0, 100)}")
        csv_bytes = ("\n".join(rows) + "\n").encode("utf-8")
        cases.append(Case("csv", f"rand_csv_{i}", csv_bytes, True, (".[0].name", "length", "map(.score)")))

        # YAML
        yaml_str = (
            f"id: {rng.randint(0, 999)}\n"
            f'name: "{rng.choice(strs)}"\n'
            f'ok: {"true" if rng.choice([True, False]) else "false"}\n'
            f"nums:\n"
            f"  - {rng.randint(-50, 50)}\n"
            f"  - {rng.randint(-50, 50)}\n"
            f"nested:\n"
            f"  score: {rng.randint(0, 500)}\n"
        )
        cases.append(Case("yaml", f"rand_yaml_{i}", yaml_str.encode("utf-8"), True, (".id", ".nested.score", ".nums | add")))

        # HTML
        html_str = (
            f"<!DOCTYPE html><html><head><title>t{i}</title></head><body>"
            f"<div><p>{rng.choice(['ada', 'grace', 'alan', 'barbara'])}</p>"
            f"<span>{rng.randint(0, 500)}</span></div>"
            f"</body></html>"
        )
        cases.append(Case("html", f"rand_html_{i}", html_str.encode("utf-8"), True, (".html.head.title", ".html.body.div.p", ".html.body.div.span")))

    return cases


def run_cmd(cmd: list[str], stdin_bytes: bytes) -> tuple[int, bytes, bytes]:
    res = subprocess.run(cmd, input=stdin_bytes, capture_output=True)
    return res.returncode, res.stdout, res.stderr


def normalize_json_lines(raw: bytes) -> list:
    lines = [ln for ln in raw.decode("utf-8").splitlines() if ln.strip() != ""]
    return [json.loads(ln) for ln in lines]


def main() -> int:
    ap = argparse.ArgumentParser(description="v1-vs-v2 differential oracle for stury")
    ap.add_argument("--odin", default=os.environ.get("ODIN", "odin"), help="Path to odin compiler")
    ap.add_argument("--v1", default=None, help="Path to v1 stury binary (built automatically if omitted)")
    ap.add_argument("--seed", type=int, default=2026, help="PRNG seed")
    ap.add_argument("--rounds", type=int, default=15, help="Randomized rounds per format")
    args = ap.parse_args()

    odin = shutil.which(args.odin) or args.odin

    with tempfile.TemporaryDirectory(prefix="stury_diff_oracle_") as td:
        tmpdir = pathlib.Path(td)
        v2_bin = build_v2_probe(odin, tmpdir)
        v1_bin = locate_or_build_v1(odin, args.v1, tmpdir)

        cases = generate_cases(args.seed, args.rounds)

        stats = {
            "validate": [0, 0],  # [agree, total]
            "canon": [0, 0],
            "jq": [0, 0],
        }
        per_fmt: dict[str, list[int]] = {}
        failures: list[str] = []

        def record(cat: str, fmt: str, ok: bool, detail: str = "") -> None:
            stats[cat][1] += 1
            per_fmt.setdefault(fmt, [0, 0])[1] += 1
            if ok:
                stats[cat][0] += 1
                per_fmt[fmt][0] += 1
            else:
                failures.append(f"[{cat}] {fmt}: {detail}")

        for c in cases:
            if c.self_check:
                # Self-check + round-trip + jq-vs-JSON parity for formats not in v1 (e.g. MessagePack).
                rc2, _, err2 = run_cmd([str(v2_bin), "validate", c.fmt], c.data)
                v2_ok = rc2 == 0
                valid_rc = rc2 in (0, 5)
                agree = valid_rc and (c.expect_valid is None or v2_ok == c.expect_valid)
                record(
                    "validate",
                    c.fmt,
                    agree,
                    f"{c.name}: rc2={rc2} expect={c.expect_valid} err2={err2!r}",
                )
                if not (valid_rc and v2_ok):
                    continue

                rc2, out2, err2 = run_cmd([str(v2_bin), "canon", c.fmt], c.data)
                rc_rt, out_rt, err_rt = run_cmd([str(v2_bin), "roundtrip", c.fmt], c.data)
                if rc2 != 0 or rc_rt != 0:
                    record("canon", c.fmt, False, f"{c.name}: canon rc={rc2} rt rc={rc_rt} err2={err2!r} err_rt={err_rt!r}")
                else:
                    try:
                        j2 = normalize_json_lines(out2)
                        jrt = normalize_json_lines(out_rt)
                        ok = j2 == [c.expect_obj] and jrt == [c.expect_obj]
                        record("canon", c.fmt, ok, f"{c.name}: expect={[c.expect_obj]!r} canon={j2!r} rt={jrt!r}")
                    except Exception as exc:
                        record("canon", c.fmt, False, f"{c.name}: parse error {exc}")

                ref_json = json.dumps(c.expect_obj, separators=(",", ":")).encode("utf-8")
                for flt in c.jq_filters:
                    rc1, out1, err1 = run_cmd([str(v2_bin), "jq", "json", flt], ref_json)
                    rc2, out2, err2 = run_cmd([str(v2_bin), "jq", c.fmt, flt], c.data)
                    if rc1 != 0 or rc2 != 0:
                        record("jq", c.fmt, False, f"{c.name} ({flt}): rc_json={rc1} rc_fmt={rc2} err1={err1!r} err2={err2!r}")
                    else:
                        try:
                            j1 = normalize_json_lines(out1)
                            j2 = normalize_json_lines(out2)
                            record("jq", c.fmt, j1 == j2, f"{c.name} ({flt}): json={j1!r} != {c.fmt}={j2!r}")
                        except Exception as exc:
                            record("jq", c.fmt, False, f"{c.name} ({flt}): parse error {exc}")
                continue

            # 1. Validate agreement (strict exit codes: 0 = valid, 5 = parse/input error; reject CLI/crash codes like 2)
            rc1, _, err1 = run_cmd([str(v1_bin), "check", "--from", c.fmt], c.data)
            rc2, _, err2 = run_cmd([str(v2_bin), "validate", c.fmt], c.data)
            v1_ok = rc1 == 0
            v2_ok = rc2 == 0
            valid_rcs = rc1 in (0, 5) and rc2 in (0, 5)
            agree = valid_rcs and v1_ok == v2_ok and (c.expect_valid is None or v2_ok == c.expect_valid)
            record(
                "validate",
                c.fmt,
                agree,
                f"{c.name}: rc1={rc1} rc2={rc2} expect={c.expect_valid} err1={err1!r} err2={err2!r}",
            )
            if not (valid_rcs and v1_ok and v2_ok):
                continue

            # 2. Canonical build -> write -> JSON agreement
            if c.fmt == "csv":
                # v1 CLI frames CSV as per-row records; `-s` slurps rows into the same table array as v2 `dsv.build`.
                v1_canon_cmd = [str(v1_bin), "-s", "-c", "--from", "csv", "."]
            else:
                v1_canon_cmd = [str(v1_bin), "fmt", "--from", c.fmt, "--to", "json", "-c"]
            rc1, out1, err1 = run_cmd(v1_canon_cmd, c.data)
            rc2, out2, err2 = run_cmd([str(v2_bin), "canon", c.fmt], c.data)
            if rc1 != 0 or rc2 != 0:
                record("canon", c.fmt, False, f"{c.name}: rc1={rc1} rc2={rc2} err1={err1!r} err2={err2!r}")
            else:
                try:
                    j1 = normalize_json_lines(out1)
                    j2 = normalize_json_lines(out2)
                    ok = j1 == j2
                    record("canon", c.fmt, ok, f"{c.name}: v1={j1!r} != v2={j2!r}")
                except Exception as exc:
                    record("canon", c.fmt, False, f"{c.name}: parse error {exc}: out1={out1!r} out2={out2!r}")

            # 3. jq query agreement
            for flt in c.jq_filters:
                v1_jq_cmd = (
                    [str(v1_bin), "-s", "-c", "--from", c.fmt, flt]
                    if c.fmt == "csv"
                    else [str(v1_bin), "-c", "--from", c.fmt, flt]
                )
                rc1, out1, err1 = run_cmd(v1_jq_cmd, c.data)
                rc2, out2, err2 = run_cmd([str(v2_bin), "jq", c.fmt, flt], c.data)
                if rc1 != 0 or rc2 != 0:
                    record("jq", c.fmt, False, f"{c.name} ({flt}): rc1={rc1} rc2={rc2} err1={err1!r} err2={err2!r}")
                else:
                    try:
                        j1 = normalize_json_lines(out1)
                        j2 = normalize_json_lines(out2)
                        ok = j1 == j2
                        record("jq", c.fmt, ok, f"{c.name} ({flt}): v1={j1!r} != v2={j2!r}")
                    except Exception as exc:
                        record("jq", c.fmt, False, f"{c.name} ({flt}): parse error {exc}")

        total_ok = sum(v[0] for v in stats.values())
        total_n = sum(v[1] for v in stats.values())
        print(f"=== stury v1-vs-v2 Differential Oracle (seed={args.seed}, rounds={args.rounds}) ===")
        for cat in ("validate", "canon", "jq"):
            ok, n = stats[cat]
            print(f"  {cat:<10s}: {ok}/{n} agree")
        print("  by format:")
        for fmt in sorted(per_fmt):
            ok, n = per_fmt[fmt]
            print(f"    {fmt:<8s}: {ok}/{n} agree")
        print(f"  TOTAL     : {total_ok}/{total_n} agree")
        if failures:
            print(f"\nMISMATCHES ({len(failures)}):")
            for f in failures[:25]:
                print("  -", f)
            return 1
        print("PASS: 100% v1-vs-v2 parity across all checks.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
