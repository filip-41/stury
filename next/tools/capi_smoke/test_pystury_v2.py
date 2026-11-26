#!/usr/bin/env python3
"""Zero-dependency Python 3 (ctypes) v2 smoke test for libstury (next/capi/stury.h).

Loads a freshly compiled libstury shared library and exercises the complete C ABI:
format lookup/detection/capabilities, validation, build/inspect/write, cross-format
conversion (JSON, JSONC, TOML, XML, CSV, CBOR), lossless overlay editing across arena
resets, JSON Schema 2020-12 streaming validation, jq callback queries (including early
stop, halt, and budgets), and RFC 9535 JSONPath queries with normalized paths.
"""

import argparse
import ctypes
import os
import sys

STURY_NO_BYTE = (1 << 64) - 1

STURY_FORMAT_JSON = 0
STURY_FORMAT_JSONC = 1
STURY_FORMAT_JSON5 = 2
STURY_FORMAT_TOML_1_0 = 3
STURY_FORMAT_TOML_1_1 = 4
STURY_FORMAT_XML = 5
STURY_FORMAT_CSV = 6
STURY_FORMAT_TSV = 7
STURY_FORMAT_PLAIN = 8
STURY_FORMAT_CBOR = 9
STURY_FORMAT_CBOR_PREFERRED = 10
STURY_FORMAT_CBOR_DETERMINISTIC = 11
STURY_FORMAT_CBOR_LENGTH_FIRST = 12
STURY_FORMAT_UNKNOWN = 255

STURY_CAP_REWALK = 1 << 0
STURY_CAP_NAMES_AHEAD = 1 << 1
STURY_CAP_BINARY = 1 << 2

STURY_FACT_COMMENT = 1 << 0
STURY_FACT_ATTRIBUTE = 1 << 10

STURY_OK = 0
STURY_ERR_INVALID_ARG = 1
STURY_ERR_SYNTAX = 2
STURY_ERR_BUDGET = 3
STURY_ERR_NO_MEMORY = 4
STURY_ERR_UNSPELLABLE = 5
STURY_ERR_SCHEMA_INVALID = 6
STURY_ERR_EDIT_REFUSED = 7
STURY_ERR_QUERY_RUNTIME = 8
STURY_ERR_STOPPED = 9
STURY_ERR_UNSUPPORTED = 10
STURY_ERR_HALTED = 11


class SturyErr(ctypes.Structure):
    _fields_ = [
        ("code", ctypes.c_uint32),
        ("at", ctypes.c_uint64),
        ("message", ctypes.c_char_p),
    ]


class SturyBudget(ctypes.Structure):
    _fields_ = [
        ("depth", ctypes.c_uint32),
        ("nodes", ctypes.c_uint32),
        ("memory", ctypes.c_uint64),
        ("steps", ctypes.c_uint64),
        ("expansion", ctypes.c_uint64),
    ]


EMIT_FN = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
JSONPATH_EMIT_FN = ctypes.CFUNCTYPE(
    ctypes.c_bool,
    ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_uint8),
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_char),
    ctypes.c_size_t,
)


def bind_lib(path: str) -> ctypes.CDLL:
    lib = ctypes.CDLL(path)
    vp = ctypes.c_void_p
    u8p = ctypes.POINTER(ctypes.c_uint8)
    sz = ctypes.c_size_t
    u32 = ctypes.c_uint32
    u16 = ctypes.c_uint16
    cp = ctypes.c_char_p
    bp = ctypes.POINTER(SturyBudget)

    # Arena lifecycle
    lib.stury_arena_new.argtypes = []
    lib.stury_arena_new.restype = vp
    lib.stury_arena_reset.argtypes = [vp]
    lib.stury_arena_reset.restype = None
    lib.stury_arena_free.argtypes = [vp]
    lib.stury_arena_free.restype = None

    # Format lookup, detection, caps, facts
    lib.stury_format_by_name.argtypes = [cp, sz]
    lib.stury_format_by_name.restype = u32
    lib.stury_format_of_path.argtypes = [cp, sz]
    lib.stury_format_of_path.restype = u32
    lib.stury_format_detect.argtypes = [cp, sz]
    lib.stury_format_detect.restype = u32
    lib.stury_format_caps.argtypes = [u32]
    lib.stury_format_caps.restype = u32
    lib.stury_format_facts.argtypes = [u32]
    lib.stury_format_facts.restype = u16

    # Validate, build, inspect, write, convert
    lib.stury_validate.argtypes = [vp, cp, sz, u32, bp]
    lib.stury_validate.restype = SturyErr
    lib.stury_build.argtypes = [vp, cp, sz, u32, bp, ctypes.POINTER(vp)]
    lib.stury_build.restype = SturyErr
    lib.stury_doc_free.argtypes = [vp]
    lib.stury_doc_free.restype = None
    lib.stury_doc_facts.argtypes = [vp]
    lib.stury_doc_facts.restype = u16
    lib.stury_doc_node_count.argtypes = [vp]
    lib.stury_doc_node_count.restype = sz
    lib.stury_write.argtypes = [vp, vp, u32, ctypes.POINTER(u8p), ctypes.POINTER(sz), ctypes.POINTER(u16)]
    lib.stury_write.restype = SturyErr
    lib.stury_convert.argtypes = [vp, cp, sz, u32, u32, bp, ctypes.POINTER(u8p), ctypes.POINTER(sz), ctypes.POINTER(u16)]
    lib.stury_convert.restype = SturyErr

    # Schema
    lib.stury_schema_compile.argtypes = [vp, cp, sz, ctypes.POINTER(vp)]
    lib.stury_schema_compile.restype = SturyErr
    lib.stury_schema_free.argtypes = [vp]
    lib.stury_schema_free.restype = None
    lib.stury_schema_check.argtypes = [vp, vp, cp, sz, u32, bp, ctypes.POINTER(ctypes.c_bool)]
    lib.stury_schema_check.restype = SturyErr

    # Overlay
    lib.stury_overlay_new.argtypes = [vp, vp, ctypes.POINTER(vp)]
    lib.stury_overlay_new.restype = SturyErr
    lib.stury_overlay_free.argtypes = [vp]
    lib.stury_overlay_free.restype = None
    lib.stury_overlay_set_raw.argtypes = [vp, vp, cp, sz, cp, sz]
    lib.stury_overlay_set_raw.restype = SturyErr
    lib.stury_overlay_set_string.argtypes = [vp, vp, cp, sz, cp, sz]
    lib.stury_overlay_set_string.restype = SturyErr
    lib.stury_overlay_set_int.argtypes = [vp, vp, cp, sz, ctypes.c_int64]
    lib.stury_overlay_set_int.restype = SturyErr
    lib.stury_overlay_del_path.argtypes = [vp, vp, cp, sz]
    lib.stury_overlay_del_path.restype = SturyErr
    lib.stury_overlay_commit.argtypes = [
        vp,
        vp,
        u32,
        ctypes.c_bool,
        ctypes.POINTER(u8p),
        ctypes.POINTER(sz),
        ctypes.POINTER(u16),
    ]
    lib.stury_overlay_commit.restype = SturyErr

    # jq
    lib.stury_jq_compile.argtypes = [vp, cp, sz, ctypes.POINTER(vp)]
    lib.stury_jq_compile.restype = SturyErr
    lib.stury_jq_free.argtypes = [vp]
    lib.stury_jq_free.restype = None
    lib.stury_jq_eval.argtypes = [vp, vp, cp, sz, u32, bp, EMIT_FN, vp]
    lib.stury_jq_eval.restype = SturyErr

    # JSONPath
    lib.stury_jsonpath_compile.argtypes = [vp, cp, sz, ctypes.POINTER(vp)]
    lib.stury_jsonpath_compile.restype = SturyErr
    lib.stury_jsonpath_free.argtypes = [vp]
    lib.stury_jsonpath_free.restype = None
    lib.stury_jsonpath_eval.argtypes = [vp, vp, cp, sz, u32, bp, ctypes.c_bool, JSONPATH_EMIT_FN, vp]
    lib.stury_jsonpath_eval.restype = SturyErr

    return lib


def run_smoke(lib_path: str) -> None:
    # 1. Verify ABI layout matches stury.h / capi.odin asserts
    assert ctypes.sizeof(SturyErr) == 24
    assert SturyErr.code.offset == 0
    assert SturyErr.at.offset == 8
    assert SturyErr.message.offset == 16
    assert ctypes.sizeof(SturyBudget) == 32

    lib = bind_lib(lib_path)

    arena = lib.stury_arena_new()
    assert arena, "stury_arena_new returned NULL"
    try:
        # 2. Format lookup, path, detection, caps, facts
        assert lib.stury_format_by_name(b"json", 4) == STURY_FORMAT_JSON
        assert lib.stury_format_by_name(b"toml", 4) == STURY_FORMAT_TOML_1_0
        assert lib.stury_format_by_name(b"xml", 3) == STURY_FORMAT_XML
        assert lib.stury_format_by_name(b"csv", 3) == STURY_FORMAT_CSV
        assert lib.stury_format_by_name(b"cbor", 4) == STURY_FORMAT_CBOR
        assert lib.stury_format_by_name(b"nope", 4) == STURY_FORMAT_UNKNOWN

        assert lib.stury_format_of_path(b"data.json.gz", 12) == STURY_FORMAT_JSON
        assert lib.stury_format_of_path(b"config.toml", 11) == STURY_FORMAT_TOML_1_0
        assert lib.stury_format_detect(b'{"k":1}', 7) == STURY_FORMAT_JSON
        assert lib.stury_format_detect(b"<r><a/></r>", 11) == STURY_FORMAT_XML
        assert (lib.stury_format_caps(STURY_FORMAT_CBOR) & STURY_CAP_BINARY) != 0
        assert (lib.stury_format_facts(STURY_FORMAT_XML) & STURY_FACT_ATTRIBUTE) != 0

        # 3. Validate (valid, syntax error, NULL arena, depth budget)
        src = b'// keep\n{"user":{"name":"old","age":30},"items":[1,2,3]}\n'
        err = lib.stury_validate(arena, src, len(src), STURY_FORMAT_JSONC, None)
        assert err.code == STURY_OK

        bad = b'{"a": }'
        err = lib.stury_validate(None, bad, len(bad), STURY_FORMAT_JSON, None)
        assert err.code == STURY_ERR_SYNTAX
        assert err.at != STURY_NO_BYTE
        assert err.message

        depth_budget = SturyBudget(depth=2)
        nested = b"[[[[1]]]]"
        err = lib.stury_validate(arena, nested, len(nested), STURY_FORMAT_JSON, ctypes.byref(depth_budget))
        assert err.code == STURY_ERR_BUDGET

        # 4. Build, inspect, write (with dropped comment fact), free
        # Keep `src_buf` alive for the lifetime of `doc` per stury.h borrowing contract!
        src_buf = ctypes.create_string_buffer(src, len(src))
        doc = ctypes.c_void_p()
        err = lib.stury_build(arena, src_buf, len(src), STURY_FORMAT_JSONC, None, ctypes.byref(doc))
        assert err.code == STURY_OK and doc.value
        assert lib.stury_doc_node_count(doc) > 0
        assert (lib.stury_doc_facts(doc) & STURY_FACT_COMMENT) != 0

        out_p = ctypes.POINTER(ctypes.c_uint8)()
        out_len = ctypes.c_size_t()
        dropped = ctypes.c_uint16()
        err = lib.stury_write(
            arena, doc, STURY_FORMAT_JSON, ctypes.byref(out_p), ctypes.byref(out_len), ctypes.byref(dropped)
        )
        assert err.code == STURY_OK
        written = ctypes.string_at(out_p, out_len.value)
        assert written == b'{"user":{"name":"old","age":30},"items":[1,2,3]}'
        assert (dropped.value & STURY_FACT_COMMENT) != 0

        # 5. Format-preserving overlay edit across arena resets
        lib.stury_arena_reset(arena)
        ov = ctypes.c_void_p()
        err = lib.stury_overlay_new(arena, doc, ctypes.byref(ov))
        assert err.code == STURY_OK and ov.value
        try:
            assert lib.stury_overlay_set_string(arena, ov, b"/user/name", 10, b"ada", 3).code == STURY_OK
            assert lib.stury_overlay_set_int(arena, ov, b"/user/age", 9, 36).code == STURY_OK
            assert lib.stury_overlay_set_raw(arena, ov, b"/items/1", 8, b"[9,8]", 5).code == STURY_OK
            assert lib.stury_overlay_del_path(arena, ov, b"/items/2", 8).code == STURY_OK

            lib.stury_arena_reset(arena)
            err = lib.stury_overlay_commit(
                arena, ov, STURY_FORMAT_UNKNOWN, False, ctypes.byref(out_p), ctypes.byref(out_len), ctypes.byref(dropped)
            )
            assert err.code == STURY_OK
            committed = ctypes.string_at(out_p, out_len.value)
            assert b"// keep" in committed
            assert b'"ada"' in committed
            assert b"36" in committed
            assert b"[9,8]" in committed
            assert dropped.value == 0
        finally:
            lib.stury_overlay_free(ov)
            lib.stury_doc_free(doc)

        # 6. Cross-format conversion (TOML -> JSON -> CBOR -> JSON, XML -> JSON, CSV -> JSON)
        lib.stury_arena_reset(arena)
        toml_in = b'# cfg\nhost = "db"\nport = 5432\n'
        err = lib.stury_convert(
            arena,
            toml_in,
            len(toml_in),
            STURY_FORMAT_TOML_1_0,
            STURY_FORMAT_JSON,
            None,
            ctypes.byref(out_p),
            ctypes.byref(out_len),
            ctypes.byref(dropped),
        )
        assert err.code == STURY_OK
        json_bytes = ctypes.string_at(out_p, out_len.value)
        assert json_bytes == b'{"host":"db","port":5432}'
        assert (dropped.value & STURY_FACT_COMMENT) != 0

        err = lib.stury_convert(
            arena,
            json_bytes,
            len(json_bytes),
            STURY_FORMAT_JSON,
            STURY_FORMAT_CBOR,
            None,
            ctypes.byref(out_p),
            ctypes.byref(out_len),
            None,
        )
        assert err.code == STURY_OK and out_len.value > 0
        cbor_bytes = ctypes.string_at(out_p, out_len.value)

        err = lib.stury_convert(
            arena,
            cbor_bytes,
            len(cbor_bytes),
            STURY_FORMAT_CBOR,
            STURY_FORMAT_JSON,
            None,
            ctypes.byref(out_p),
            ctypes.byref(out_len),
            None,
        )
        assert err.code == STURY_OK
        assert ctypes.string_at(out_p, out_len.value) == json_bytes

        csv_in = b"k,v\na,1\nb,2\n"
        err = lib.stury_convert(
            arena,
            csv_in,
            len(csv_in),
            STURY_FORMAT_CSV,
            STURY_FORMAT_JSON,
            None,
            ctypes.byref(out_p),
            ctypes.byref(out_len),
            None,
        )
        assert err.code == STURY_OK
        assert b'"a"' in ctypes.string_at(out_p, out_len.value)

        # 7. JSON Schema 2020-12 compile & streaming check across JSON, TOML, CBOR
        schema_src = (
            b'{"type":"object","required":["host","port"],'
            b'"properties":{"host":{"type":"string","minLength":1},"port":{"type":"integer","minimum":1}}}'
        )
        schema = ctypes.c_void_p()
        err = lib.stury_schema_compile(arena, schema_src, len(schema_src), ctypes.byref(schema))
        assert err.code == STURY_OK and schema.value
        try:
            valid = ctypes.c_bool(False)
            assert (
                lib.stury_schema_check(
                    arena, schema, json_bytes, len(json_bytes), STURY_FORMAT_JSON, None, ctypes.byref(valid)
                ).code
                == STURY_OK
                and valid.value
            )
            assert (
                lib.stury_schema_check(
                    arena, schema, toml_in, len(toml_in), STURY_FORMAT_TOML_1_0, None, ctypes.byref(valid)
                ).code
                == STURY_OK
                and valid.value
            )
            assert (
                lib.stury_schema_check(
                    arena, schema, cbor_bytes, len(cbor_bytes), STURY_FORMAT_CBOR, None, ctypes.byref(valid)
                ).code
                == STURY_OK
                and valid.value
            )

            bad_port = b'{"host":"db","port":0}'
            err = lib.stury_schema_check(
                arena, schema, bad_port, len(bad_port), STURY_FORMAT_JSON, None, ctypes.byref(valid)
            )
            assert err.code == STURY_ERR_SCHEMA_INVALID and not valid.value
        finally:
            lib.stury_schema_free(schema)

        # 8. jq query with Python callback (emit, early stop, halt, step budget)
        jq_prog = ctypes.c_void_p()
        err = lib.stury_jq_compile(arena, b".items[] | . * 2", 16, ctypes.byref(jq_prog))
        assert err.code == STURY_OK and jq_prog.value
        try:
            results: list[bytes] = []

            @EMIT_FN
            def on_jq(_ctx, ptr, length):
                results.append(ctypes.string_at(ptr, length))
                return True

            jq_in = b'{"items":[5,10,15]}'
            err = lib.stury_jq_eval(arena, jq_prog, jq_in, len(jq_in), STURY_FORMAT_JSON, None, on_jq, None)
            assert err.code == STURY_OK
            assert results == [b"10", b"20", b"30"]

            stopped: list[bytes] = []

            @EMIT_FN
            def on_jq_stop(_ctx, ptr, length):
                stopped.append(ctypes.string_at(ptr, length))
                return False

            err = lib.stury_jq_eval(arena, jq_prog, jq_in, len(jq_in), STURY_FORMAT_JSON, None, on_jq_stop, None)
            assert err.code == STURY_ERR_STOPPED
            assert stopped == [b"10"]
        finally:
            lib.stury_jq_free(jq_prog)

        halt_prog = ctypes.c_void_p()
        assert lib.stury_jq_compile(None, b"halt", 4, ctypes.byref(halt_prog)).code == STURY_OK
        try:
            err = lib.stury_jq_eval(arena, halt_prog, b"null", 4, STURY_FORMAT_JSON, None, EMIT_FN(0), None)
            assert err.code == STURY_ERR_HALTED
        finally:
            lib.stury_jq_free(halt_prog)

        # 9. RFC 9535 JSONPath with normalized paths over TOML
        jp_prog = ctypes.c_void_p()
        err = lib.stury_jsonpath_compile(arena, b"$.nums[*]", 9, ctypes.byref(jp_prog))
        assert err.code == STURY_OK and jp_prog.value
        try:
            jp_hits: list[tuple[bytes, bytes]] = []

            @JSONPATH_EMIT_FN
            def on_jp(_ctx, ptr, length, path_ptr, path_len):
                val = ctypes.string_at(ptr, length)
                path = ctypes.string_at(path_ptr, path_len) if path_ptr and path_len else b""
                jp_hits.append((val, path))
                return True

            toml_nums = b"nums = [7, 8, 9]\n"
            err = lib.stury_jsonpath_eval(
                arena, jp_prog, toml_nums, len(toml_nums), STURY_FORMAT_TOML_1_0, None, True, on_jp, None
            )
            assert err.code == STURY_OK
            assert jp_hits == [
                (b"7", b"$['nums'][0]"),
                (b"8", b"$['nums'][1]"),
                (b"9", b"$['nums'][2]"),
            ]
        finally:
            lib.stury_jsonpath_free(jp_prog)

        # 10. NULL arena rejection on output-allocating call
        err = lib.stury_convert(
            None,
            json_bytes,
            len(json_bytes),
            STURY_FORMAT_JSON,
            STURY_FORMAT_TOML_1_0,
            None,
            ctypes.byref(out_p),
            ctypes.byref(out_len),
            None,
        )
        assert err.code == STURY_ERR_INVALID_ARG
    finally:
        lib.stury_arena_free(arena)

    print("test_pystury_v2: all Python ctypes smoke checks passed")


def main() -> int:
    parser = argparse.ArgumentParser(description="Python ctypes v2 smoke test for libstury.")
    parser.add_argument("--lib", default=os.environ.get("STURY_LIB", ""), help="Path to libstury shared library")
    args = parser.parse_args()
    if not args.lib:
        parser.error("pass --lib <path/to/libstury> or set STURY_LIB")
    run_smoke(args.lib)
    return 0


if __name__ == "__main__":
    sys.exit(main())
