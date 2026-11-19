"""A directory argument's walk, where a cli.tsv row cannot hold the tree: symlinks and junctions are not followed, an
unreadable directory is told and the run goes on with exit 2, names may hold line ends, bytes that are not UTF-8 or
decomposed accents, Windows paths may pass 260 characters, and the order is the byte order of the paths."""

import os
import random
import shutil
import subprocess
import sys

import pytest

POSIX = pytest.mark.skipif(os.name == "nt", reason="POSIX symlinks and modes")
WINDOWS = pytest.mark.skipif(os.name != "nt", reason="Windows paths and attributes")


def run(stury, cwd, *args):
    p = subprocess.run([stury, *args], cwd=cwd, capture_output=True)
    return p.returncode, p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


@POSIX
def test_symlinks_not_followed(stury, tmp_path):
    write(tmp_path / "out/a.json", "1")
    write(tmp_path / "d/b.json", "2")
    os.symlink(tmp_path / "out/a.json", tmp_path / "d/link.json")
    os.symlink(tmp_path / "out", tmp_path / "d/linked")
    os.symlink(tmp_path / "d", tmp_path / "d/loop")
    assert run(stury, tmp_path, "-c", "input_filename", "d") == (0, '"d/b.json"\n', "")
    # A symlink named on the command line is read through, a directory's walked.
    os.symlink(tmp_path / "d", tmp_path / "named")
    assert run(stury, tmp_path, "-c", ".", "d/link.json", "d/linked", "named") == (0, "1\n1\n2\n", "")


@POSIX
@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="root reads any file")
def test_unreadable(stury, tmp_path):
    write(tmp_path / "d/a/x.json", "1")
    write(tmp_path / "d/b.json", "2")
    write(tmp_path / "d/c.json", "3")
    write(tmp_path / "d/d.json", "4")
    os.chmod(tmp_path / "d/a", 0)
    os.chmod(tmp_path / "d/c.json", 0)
    try:
        # A filter run reads one input past a file that did not open, as jq's main loop does.
        stream = run(stury, tmp_path, "-c", ".", "d")
        checked = run(stury, tmp_path, "check", "d")
    finally:
        os.chmod(tmp_path / "d/a", 0o755)
    assert stream == (2, "2\n", "stury: error: Could not open directory d/a: Permission denied\n"
                                "stury: hint: --each runs each file on its own\n")
    assert checked == (2, "", "stury: error: Could not open directory d/a: Permission denied\n"
                              "stury: error: Could not open file d/c.json: Permission denied\n")


@POSIX
def test_line_end_and_tab_in_name(stury, tmp_path):
    write(tmp_path / "d/a\nb\tc.json", "1")
    assert run(stury, tmp_path, "-c", "input_filename", "d") == (0, '"d/a\\nb\\tc.json"\n', "")


@pytest.mark.skipif(sys.platform != "linux", reason="a name that is not UTF-8")
def test_name_not_utf8(stury, tmp_path):
    os.makedirs(tmp_path / "d")
    with open(os.path.join(os.fsencode(tmp_path / "d"), b"\xff.json"), "w") as f:
        f.write("1")
    assert run(stury, tmp_path, "-c", "input_filename", "d") == (0, '"d/�.json"\n', "")


def types_unknown(path):
    """Whether readdir gives DT_UNKNOWN for the entries of `path`, as a file system without entry types does."""
    import ctypes

    class Dirent(ctypes.Structure):
        _fields_ = [("ino", ctypes.c_uint64), ("off", ctypes.c_int64), ("reclen", ctypes.c_ushort), ("type", ctypes.c_ubyte),
                    ("name", ctypes.c_char * 256)]

    libc = ctypes.CDLL(None, use_errno=True)
    libc.opendir.restype, libc.readdir.restype = ctypes.c_void_p, ctypes.POINTER(Dirent)
    libc.readdir.argtypes = libc.closedir.argtypes = [ctypes.c_void_p]
    d = libc.opendir(os.fsencode(path))
    types = set()
    while e := libc.readdir(d):
        types.add(e.contents.type)
    libc.closedir(d)
    return types == {0}


@pytest.mark.skipif(sys.platform != "linux", reason="glibc's struct dirent")
def test_entry_types_unknown(stury, tmp_path):
    """A file system that gives no entry types is walked through lstat, with the same answers."""
    write(tmp_path / "d/a.json", "1")
    write(tmp_path / "d/s/b.json", "2")
    os.symlink(tmp_path / "d/a.json", tmp_path / "d/link.json")
    if not types_unknown(tmp_path / "d"):
        pytest.skip("the file system gives entry types")
    assert run(stury, tmp_path, "-c", "[input_filename, .]", "d") == (0, '["d/a.json",1]\n["d/s/b.json",2]\n', "")


@pytest.mark.skipif(sys.platform != "darwin", reason="names as macOS stores them")
def test_decomposed_name(stury, tmp_path):
    for name in ("é.json", "f.json", "éa.json"):
        write(tmp_path / "d" / name, "1")
    want = sorted(os.listdir(tmp_path / "d"), key=os.fsencode)
    code, out, _ = run(stury, tmp_path, "-r", "input_filename", "d")
    assert (code, out.splitlines()) == (0, [f"d/{n}" for n in want])


@WINDOWS
def test_windows_links_skipped(stury, tmp_path):
    write(tmp_path / "out/a.json", "1")
    write(tmp_path / "d/b.json", "2")
    subprocess.run(["cmd", "/c", "mklink", "/J", str(tmp_path / "d/junction"), str(tmp_path / "out")], check=True, capture_output=True)
    try:
        os.symlink(tmp_path / "out/a.json", tmp_path / "d/link.json")
    except OSError:
        pass
    assert run(stury, tmp_path, "-c", "input_filename", "d") == (0, '"d/b.json"\n', "")


@WINDOWS
def test_windows_paths(stury, tmp_path):
    deep = tmp_path / "d" / ("x" * 100) / ("y" * 100) / ("z" * 60)
    write(deep / "a.json", "1")
    write(tmp_path / "d/h.json", "2")
    subprocess.run(["attrib", "+h", str(tmp_path / "d/h.json")], check=True)
    code, out, _ = run(stury, tmp_path, "-c", ".", "d")
    assert (code, out) == (0, "2\n1\n")
    # The root is kept as typed, and the names below it are joined with `/`.
    assert run(stury, tmp_path, "-r", "input_filename", "-g", "h.json", "d\\")[1] == "d\\h.json\n"
    assert run(stury, tmp_path, "-r", "input_filename", "-g", "h.json", "d")[1] == "d/h.json\n"
    write(tmp_path / "f/a.json", '{"a":1}')
    assert run(stury, tmp_path, "fmt", "--in-place", "f") == (0, "", "")
    with open(tmp_path / "f/a.json") as f:
        assert f.read() == '{\n  "a": 1\n}\n'


def test_order(stury, tmp_path):
    rng = random.Random(7)
    names = ["a", "B", "_", "a.b", "a-b", "é", "Z", "0", "a b", "~", "a0", "ab"]
    count = 0

    def fill(rel, depth):
        nonlocal count
        for name in rng.sample(names, 8):
            if depth < 3 and rng.random() < 0.5:
                fill(f"{rel}/{name}", depth + 1)
            else:
                write(tmp_path / f"{rel}/{name}.json", "1")
                count += 1
    while count < 2000:
        fill(f"d/{count}", 0)
    want = sorted((os.path.relpath(os.path.join(r, f), tmp_path).replace(os.sep, "/")
                   for r, _, fs in os.walk(tmp_path / "d") for f in fs), key=lambda p: p.encode())
    code, out, _ = run(stury, tmp_path, "-r", "input_filename", "d")
    assert (code, out.splitlines()) == (0, want)


@pytest.fixture(scope="module")
def tree(tmp_path_factory):
    root = tmp_path_factory.mktemp("files")
    for i in range(200):
        text = '{"a": %d, "s": "x%d"}\n{"a": %d}\n' % (i, i, i + 1000)
        text = {50: '{"a": "str"}\n{"a": 2}\n', 90: "﻿[1]", 150: "a: 5\n"}.get(i, text)
        write(root / f"d/{'s/' if i % 3 else ''}f{i:03}.{'yaml' if i == 150 else 'json'}", text)
    write(root / "d/big.json", "[" + ",".join('{"a":%d}' % i for i in range(100000)) + "]")
    write(root / "e/f120.json", '{"a": \n')
    write(root / "y/a.toml", "a = [\n")
    return root


# Files on the pool's threads answer as on one: a filter error, a parse error ending the run, a byte order mark after a
# text, a long file the pieces share, a YAML file among JSON ones, and the filters and commands that read across files.
@pytest.mark.parametrize("args", [
    ["-c", ".a + 1", "d"], ["-c", ".a", "d"], ["-c", "[.a, input_filename]", "d"], ["-e", ".a", "d"],
    ["-c", ".a", "d", "e", "d"], ["-c", ".a", "d/s", "y", "d"], ["--each", "-c", ".a", "d/s", "y", "d"],
    ["-c", "debug | .a", "d"], ["-c", "input_filename | stderr", "d"],
    ["-s", "-c", "length", "d"], ["-n", "-c", "[inputs] | length", "d"], ["-n", "reduce inputs as $x (0; . + 1)", "d"],
    ["check", "d", "e"], ["fmt", "--check", "d"], ["fmt", "d", "e"], ["fmt", "--to", "json", "-c", "d"],
    ["edit", "--diff", ".a = 1", "d/s"], ["edit", ".a += 1", "d", "e"], ["edit", "--check", ".a = 1", "d"],
    ["--each", "-c", ".a + 1", "d", "e"], ["--each", "-n", "-c", "[input_filename, ([inputs] | length)]", "d"],
    ["--each", "-c", "debug | .a", "d"], ["--each", "-s", "-c", "length", "d"], ["--each", "--to", "csv", "{a}", "d/s"],
    ["--each", "-c", "if .a == 120 then halt_error else .a end", "d"],
])
def test_threads_answer_as_one(stury, tree, args):
    want = run(stury, tree, "--threads", "1", *args)
    for n in ("2", "8"):
        assert run(stury, tree, "--threads", n, *args) == want


@pytest.mark.parametrize("args", [["fmt", "--in-place", "--indent", "1"], ["edit", "--in-place", ".a = 1"]])
def test_threads_rewrite_as_one(stury, tree, tmp_path, args):
    def rewrite(n):
        shutil.copytree(tree / "d", tmp_path / n)
        answer = run(stury, tmp_path, "--threads", n, *args, n)
        return answer[0], answer[1], answer[2].replace(n + "/", ""), sorted(
            (p.name, p.read_bytes()) for p in (tmp_path / n).rglob("*.*"))
    assert rewrite("2") == rewrite("1") == rewrite("8")


def test_each_labels_a_long_file(stury, tree):
    """--each labels the lines and outputs the pieces of a long file write, as those of a short one."""
    code, out, _ = run(stury, tree, "--each", "-c", ".[] | .a", "d/big.json", "d/f000.json")
    assert code == 5 and out.count("\n") == 100000 and all(line.startswith("d/big.json:") for line in out.splitlines())
    code, out, _ = run(stury, tree, "--each", "-j", ".[] | .a", "d/big.json", "d/f003.json")
    assert out.count("d/big.json:") == 100000
