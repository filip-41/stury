#!/usr/bin/env python3
"""Builds libstury as a native shared library in /tmp and verifies C99, C11, C++11,
Clang ASan cross-language FFI safety, and the Python ctypes v2 smoke test.

Never leaves build artifacts in the git working tree.
"""

import argparse
import ctypes
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile


NEXT_DIR = pathlib.Path(__file__).resolve().parent.parent
CAPI_DIR = NEXT_DIR / "capi"
C_TEST_SRC = CAPI_DIR / "test" / "c_consumer_test.c"
PY_SMOKE = NEXT_DIR / "tools" / "capi_smoke" / "test_pystury_v2.py"


def run(cmd: list[str], *, env: dict[str, str] | None = None, label: str) -> None:
    print(f"== {label}")
    proc = subprocess.run(cmd, env=env)
    if proc.returncode != 0:
        raise SystemExit(f"FAILED ({proc.returncode}): {' '.join(cmd)}")


def shared_ext() -> str:
    sys_name = platform.system()
    if sys_name == "Darwin":
        return ".dylib"
    if sys_name == "Windows":
        return ".dll"
    return ".so"


def find_asan_clang() -> tuple[str | None, str | None]:
    """Returns (clang_path, extra_path_dir) matching Odin's LLVM ASan runtime."""
    # On macOS, Odin links against Homebrew LLVM's ASan runtime (`__asan_version_mismatch_check_v8`).
    for candidate in (
        os.environ.get("SAN_LLVM", ""),
        "/opt/homebrew/opt/llvm@22/bin",
        "/usr/local/opt/llvm@22/bin",
    ):
        if candidate:
            cpath = pathlib.Path(candidate) / "clang"
            if cpath.is_file() and os.access(cpath, os.X_OK):
                return str(cpath), candidate
    clang = shutil.which("clang")
    return clang, None


def rpath_flags(lib_dir: pathlib.Path) -> list[str]:
    if platform.system() == "Windows":
        return []
    return [f"-Wl,-rpath,{lib_dir}"]


def fix_darwin_install_name(lib_path: pathlib.Path) -> None:
    if platform.system() != "Darwin":
        return
    tool = shutil.which("install_name_tool")
    if tool:
        subprocess.run([tool, "-id", str(lib_path), str(lib_path)], check=True)


def run_py_extra_formats(lib_path: pathlib.Path) -> None:
    """Verifies YAML, HTML, and MessagePack through libstury via Python ctypes."""
    print("== run Python ctypes smoke for YAML, HTML, and MessagePack")

    class SturyErr(ctypes.Structure):
        _fields_ = [("code", ctypes.c_uint32), ("at", ctypes.c_uint64), ("message", ctypes.c_char_p)]

    EMIT_FN = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
    lib = ctypes.CDLL(str(lib_path))
    vp, cp, sz, u32, u16 = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint16
    u8p = ctypes.POINTER(ctypes.c_uint8)

    lib.stury_arena_new.restype = vp
    lib.stury_arena_free.argtypes = [vp]
    lib.stury_format_by_name.argtypes = [cp, sz]
    lib.stury_format_by_name.restype = u32
    lib.stury_validate.argtypes = [vp, cp, sz, u32, vp]
    lib.stury_validate.restype = SturyErr
    lib.stury_convert.argtypes = [vp, cp, sz, u32, u32, vp, ctypes.POINTER(u8p), ctypes.POINTER(sz), ctypes.POINTER(u16)]
    lib.stury_convert.restype = SturyErr
    lib.stury_jq_compile.argtypes = [vp, cp, sz, ctypes.POINTER(vp)]
    lib.stury_jq_compile.restype = SturyErr
    lib.stury_jq_free.argtypes = [vp]
    lib.stury_jq_eval.argtypes = [vp, vp, cp, sz, u32, vp, EMIT_FN, vp]
    lib.stury_jq_eval.restype = SturyErr

    FMT_JSON = 0
    FMT_YAML = 13
    FMT_YAML_MERGE = 14
    FMT_HTML = 15
    FMT_HTML_FRAG = 16
    FMT_MSGPACK = 17
    FMT_MSGPACK_COMPACT = 18

    assert lib.stury_format_by_name(b"yaml", 4) == FMT_YAML
    assert lib.stury_format_by_name(b"yaml:merge", 10) == FMT_YAML_MERGE
    assert lib.stury_format_by_name(b"html", 4) == FMT_HTML
    assert lib.stury_format_by_name(b"html:fragment", 13) == FMT_HTML_FRAG
    assert lib.stury_format_by_name(b"msgpack", 7) == FMT_MSGPACK
    assert lib.stury_format_by_name(b"msgpack:compact", 15) == FMT_MSGPACK_COMPACT

    arena = lib.stury_arena_new()
    assert arena
    try:
        out_p, out_len = u8p(), sz()
        yml = b"name: ada\nage: 36\n"
        assert lib.stury_validate(arena, yml, len(yml), FMT_YAML, None).code == 0
        assert lib.stury_convert(arena, yml, len(yml), FMT_YAML, FMT_MSGPACK_COMPACT, None, ctypes.byref(out_p), ctypes.byref(out_len), None).code == 0
        mp_bytes = ctypes.string_at(out_p, out_len.value)
        assert lib.stury_validate(arena, mp_bytes, len(mp_bytes), FMT_MSGPACK_COMPACT, None).code == 0
        assert lib.stury_convert(arena, mp_bytes, len(mp_bytes), FMT_MSGPACK, FMT_JSON, None, ctypes.byref(out_p), ctypes.byref(out_len), None).code == 0
        assert ctypes.string_at(out_p, out_len.value) == b'{"name":"ada","age":36}'

        html = b"<!DOCTYPE html><html><body><p>ada</p></body></html>"
        assert lib.stury_validate(arena, html, len(html), FMT_HTML, None).code == 0
        assert lib.stury_convert(arena, html, len(html), FMT_HTML, FMT_JSON, None, ctypes.byref(out_p), ctypes.byref(out_len), None).code == 0
        assert b'"ada"' in ctypes.string_at(out_p, out_len.value)

        jqp = vp()
        assert lib.stury_jq_compile(arena, b".name", 5, ctypes.byref(jqp)).code == 0
        try:
            hits: list[bytes] = []

            @EMIT_FN
            def on_emit(_ctx, ptr, length):
                hits.append(ctypes.string_at(ptr, length))
                return True

            assert lib.stury_jq_eval(arena, jqp, yml, len(yml), FMT_YAML, None, on_emit, None).code == 0
            assert lib.stury_jq_eval(arena, jqp, mp_bytes, len(mp_bytes), FMT_MSGPACK, None, on_emit, None).code == 0
            assert hits == [b'"ada"', b'"ada"']
        finally:
            lib.stury_jq_free(jqp)
    finally:
        lib.stury_arena_free(arena)


def default_odin() -> str:
    env_odin = os.environ.get("ODIN", "")
    if env_odin:
        return env_odin
    local_v2 = pathlib.Path("/Users/filip/Projects/Odin-v2/odin")
    if local_v2.is_file() and os.access(local_v2, os.X_OK):
        return str(local_v2)
    return "odin"


def main() -> int:
    parser = argparse.ArgumentParser(description="End-to-end native C/C++/ASan/Python C API test runner.")
    parser.add_argument("--odin", default=default_odin(), help="Path to odin compiler")
    parser.add_argument("--skip-asan", action="store_true", help="Skip ASan build/run")
    args = parser.parse_args()

    odin = shutil.which(args.odin) or args.odin
    cc = shutil.which("clang") or shutil.which("cc")
    cxx = shutil.which("clang++") or shutil.which("c++")
    if not cc or not cxx:
        raise SystemExit("C/C++ compiler (clang/clang++ or cc/c++) not found in PATH")

    ext = shared_ext()
    collection = f"-collection:stury={NEXT_DIR}"

    with tempfile.TemporaryDirectory(prefix="stury-capi-") as tmp_str:
        tmp = pathlib.Path(tmp_str)
        lib_plain = tmp / f"libstury{ext}"

        # 1. Build plain libstury shared library
        run(
            [
                odin,
                "build",
                str(CAPI_DIR),
                "-build-mode:shared",
                "-no-entry-point",
                collection,
                "-o:minimal",
                f"-out:{lib_plain}",
            ],
            label="build libstury (shared)",
        )
        fix_darwin_install_name(lib_plain)

        # 2. C99 compile + link + run
        bin_c99 = tmp / "c_consumer_c99"
        run(
            [
                cc,
                "-std=c99",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-pedantic",
                str(C_TEST_SRC),
                str(lib_plain),
                *rpath_flags(tmp),
                "-o",
                str(bin_c99),
            ],
            label="compile c_consumer_test.c (C99 -Wall -Wextra -Werror -pedantic)",
        )
        run([str(bin_c99)], label="run c_consumer_test (C99)")

        # 3. C11 compile + link + run
        bin_c11 = tmp / "c_consumer_c11"
        run(
            [
                cc,
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                str(C_TEST_SRC),
                str(lib_plain),
                *rpath_flags(tmp),
                "-o",
                str(bin_c11),
            ],
            label="compile c_consumer_test.c (C11 -Wall -Wextra -Werror)",
        )
        run([str(bin_c11)], label="run c_consumer_test (C11)")

        # 4. C++11 header + consumer compile + link + run
        bin_cxx11 = tmp / "c_consumer_cxx11"
        run(
            [
                cxx,
                "-x",
                "c++",
                "-std=c++11",
                "-Wall",
                "-Wextra",
                "-Werror",
                str(C_TEST_SRC),
                "-x",
                "none",
                str(lib_plain),
                *rpath_flags(tmp),
                "-o",
                str(bin_cxx11),
            ],
            label="compile stury.h + consumer (C++11 -Wall -Wextra -Werror)",
        )
        run([str(bin_cxx11)], label="run c_consumer_test (C++11)")

        # 5. Python ctypes v2 smoke test (all 8 formats)
        run(
            [sys.executable, str(PY_SMOKE), "--lib", str(lib_plain)],
            label="run test_pystury_v2.py (Python ctypes)",
        )
        run_py_extra_formats(lib_plain)

        # 6. Clang ASan cross-language FFI memory safety test
        if not args.skip_asan:
            asan_cc, asan_bin_dir = find_asan_clang()
            if not asan_cc:
                raise SystemExit("clang not found for ASan run")
            asan_env = os.environ.copy()
            if asan_bin_dir:
                asan_env["PATH"] = f"{asan_bin_dir}:{asan_env.get('PATH', '')}"
            if platform.system() == "Darwin":
                asan_env["ASAN_OPTIONS"] = "detect_leaks=0"

            lib_asan = tmp / f"libstury_asan{ext}"
            run(
                [
                    odin,
                    "build",
                    str(CAPI_DIR),
                    "-build-mode:shared",
                    "-no-entry-point",
                    collection,
                    "-o:minimal",
                    "-debug",
                    "-sanitize:address",
                    f"-out:{lib_asan}",
                ],
                env=asan_env,
                label="build libstury_asan (shared + ASan)",
            )
            fix_darwin_install_name(lib_asan)

            bin_asan = tmp / "c_consumer_asan"
            run(
                [
                    asan_cc,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-g",
                    "-fsanitize=address",
                    str(C_TEST_SRC),
                    str(lib_asan),
                    *rpath_flags(tmp),
                    "-o",
                    str(bin_asan),
                ],
                env=asan_env,
                label="compile c_consumer_test.c (C11 + Clang ASan)",
            )
            run([str(bin_asan)], env=asan_env, label="run c_consumer_test (Clang ASan)")

    print("test_capi: ALL CHECKS PASSED (C99, C11, C++11, Python ctypes, Clang ASan)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
