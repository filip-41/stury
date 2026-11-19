"""A run over many files holds one file's memory at a time: the peak resident size over 40 copies of a file stays near the
peak over the first few, for NDJSON, a root array (the one-document route), CSV and -R, on one thread and on a pool of
fixed width. Each file is long enough to be answered in pieces on the pool's threads."""

import json
import os

import pytest

from capped import peak

pytestmark = pytest.mark.skipif(os.name == "nt", reason="reads the peak from rusage")

COPIES = 40
RECORDS = 100000
# The pool lane's width. A thread that takes part maps an arena of its own, so the peak depends on how many woke, and that
# varies with the host's load, by at most one arena for each thread past the first. The base run has twice as many files
# as the pool has threads, so every thread has had files to take before the peak is read.
POOL_WIDTH = 3
ARENA = 12 << 20
# The peak over many files may pass the peak over the base run by this many bytes.
SLACK = 8 << 20
# A schema check of one file of records holds no memory per record, and fmt --schema of a table holds the file and its
# converted text, not a document of it: the peak of either stays within a few times the file.
SCHEMA_PEAK = 64 << 20
# A stream of regex pieces over long strings that need decoding holds the pieces live, not what making them took.
PIECES_PEAK = 32 << 20
PIECE_FILTERS = ('[.[].body | splits(" +")] | length', 'reduce (.[].body | splits(" +")) as $p (0; . + 1)',
                 '[.[].body | scan("[a-z]+")] | length', '[.[].body | . as $s | range(0; length; 3) | $s[.:. + 3]] | length')
# schema sample holds one value at a time: the peak of a long run stays under this.
SAMPLE_PEAK = 16 << 20
SAMPLES = 200000
TABLE_SCHEMA = '{"type":"array","items":{"properties":{"id":{"type":"integer"},"ok":{"type":"boolean"}}}}'
SCHEMA = '{"properties":{"id":{"type":"integer"},"level":{"enum":["info","warn"]},"msg":{"type":"string","maxLength":200}}}'
# Per width: its --threads option, the slack its threads' arenas may add, and the file count of the base run.
WIDTHS = {"1 thread": (["--threads", "1"], 0, 1), "pool": (["--threads", str(POOL_WIDTH)], (POOL_WIDTH - 1) * ARENA, 2 * POOL_WIDTH - 1)}


def fixtures():
    """The three kinds of file, each about 10 MiB, as {name: text}."""
    rows = [f'{{"id":{i},"level":"info","msg":"request {i} served from the cache after a short wait","ok":true}}' for i in range(RECORDS)]
    csv = ["id,level,msg,ok"] + [f'{i},info,"request {i} served, from the cache",true' for i in range(RECORDS)]
    return {"ndjson": "\n".join(rows) + "\n", "json": "[" + ",\n".join(rows) + "]\n", "csv": "\n".join(csv) + "\n"}


def pieces_fixture():
    """An array of 400 records, each a body of about 3 KB with line breaks written as escapes."""
    words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "elit", "sed"]
    bodies = [{"id": i, "body": "\n".join(" ".join(words[(i + j + k) % len(words)] for k in range(60)) for j in range(8))} for i in range(400)]
    return json.dumps(bodies, separators=(",", ":"))


@pytest.fixture(scope="module")
def inputs(tmp_path_factory):
    """The paths of each kind's COPIES files, which are links to the first, and the schemas and the pieces file."""
    tmp = tmp_path_factory.mktemp("memory")
    paths = {}
    for kind, text in fixtures().items():
        first = tmp / f"{kind}-0"
        first.write_text(text)
        paths[kind] = [str(first)]
        for i in range(1, COPIES):
            link = tmp / f"{kind}-{i}"
            os.link(first, link)
            paths[kind].append(str(link))
    for name, text in (("schema", SCHEMA), ("table", TABLE_SCHEMA), ("pieces", pieces_fixture())):
        (tmp / f"{name}.json").write_text(text)
        paths[name] = str(tmp / f"{name}.json")
    return paths


def peak_over(stury, args, files):
    """The most resident bytes a run of `stury` over `files` held."""
    status, err, held = peak([stury, *args, *files])
    assert status == 0, (args, status, err)
    return held


@pytest.mark.parametrize("lane", WIDTHS)
def test_schema_sample_holds_one_value(stury, inputs, lane):
    held = peak_over(stury, ["schema", "sample", "-c", "--count", str(SAMPLES)], [inputs["schema"]])
    assert held <= SAMPLE_PEAK, f"{held >> 20} MiB"


@pytest.mark.parametrize("filter", PIECE_FILTERS)
@pytest.mark.parametrize("lane", WIDTHS)
def test_regex_pieces_are_not_held(stury, inputs, lane, filter):
    held = peak_over(stury, WIDTHS[lane][0] + ["-c", filter], [inputs["pieces"]])
    assert held <= PIECES_PEAK, f"{held >> 20} MiB"


LANES = (("ndjson", ["-c", "."]), ("json", ["-c", "."]), ("csv", ["-c", "--from", "csv", "."]), ("ndjson", ["-R", "."]),
         ("ndjson", ["check", "--schema", "{schema}"]), ("csv", ["fmt", "--schema", "{table}", "--from", "csv", "--infer", "--to", "ndjson"]))


@pytest.mark.parametrize("kind, args", LANES, ids=[f"{k} {' '.join(a)}" for k, a in LANES])
@pytest.mark.parametrize("lane", WIDTHS)
def test_many_files_hold_one_files_memory(stury, inputs, lane, kind, args):
    width, arenas, base = WIDTHS[lane]
    args = [a.format(**inputs) for a in args]
    one, many = peak_over(stury, width + args, inputs[kind][:base]), peak_over(stury, width + args, inputs[kind])
    assert many <= one + SLACK + arenas, f"{base} files {one >> 20} MiB, {COPIES} files {many >> 20} MiB"
    assert args[0] not in ("check", "fmt") or one <= SCHEMA_PEAK, f"{one >> 20} MiB for one file"


# Files answered on the pool's threads while the first is still running hold at most 64 MiB of their output, whether
# they are many with little output each or few with much.
HELD_PEAK = 96 << 20


@pytest.mark.parametrize("files, lines", [(5000, 40), (90, 50000)])
def test_files_ahead_hold_bounded_output(stury, tmp_path, files, lines):
    for i in range(files):
        (tmp_path / f"f{i:05}.json").write_text('{"slow": %d, "lines": %d}' % (20000000 if i == 0 else 0, lines))
    filter = '(reduce range(.slow) as $i (0; . + 1) | empty), (range(.lines) | "%s")' % ("x" * 100)
    held = peak_over(stury, ["--threads", str(POOL_WIDTH), "-r", filter], [str(tmp_path)])
    assert held <= HELD_PEAK, f"{held >> 20} MiB"
