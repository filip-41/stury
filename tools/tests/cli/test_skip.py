"""--skip-bad and --quarantine over inputs long enough for the pool's pieces: the output, the messages, the quarantine and
the exit status are those of one thread at every --threads, with the bad records in input order."""

import json
import subprocess

import pytest

COUNT = 40000
BAD = (3, 17000, 17001, COUNT - 1)
SCHEMA = '{"type":"object","properties":{"i":{"type":"integer"}},"required":["i"]}'
WRONG = (5, 30000)


def lines(wrong=()):
    return [("{bad" if i in BAD else '{"i":"x"}' if i in wrong else '{"i":%d}' % i) for i in range(COUNT)]


@pytest.fixture
def records(tmp_path):
    path = tmp_path / "r.ndjson"
    path.write_text("\n".join(lines(WRONG)) + "\n")
    (tmp_path / "s.json").write_text(SCHEMA)
    return tmp_path


def run(stury, cwd, *args):
    p = subprocess.run([stury, *args], cwd=cwd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


@pytest.mark.parametrize("threads", ("1", "2", "6"))
def test_filter_skips_bad_records_in_order(stury, records, threads):
    code, out, err = run(stury, records, "--skip-bad", "--threads", threads, "--from", "ndjson", ".i", "r.ndjson")
    assert code == 5
    assert out.split() == [json.dumps(i) if i not in WRONG else '"x"' for i in range(COUNT) if i not in BAD]
    assert err.count("stury: ignoring parse error: r.ndjson:") == len(BAD)
    assert [line.split(":")[3] for line in err.splitlines() if line.startswith("stury: ignoring")] == [str(i + 1) for i in BAD]
    assert err.endswith(f"stury: {len(BAD)} bad records skipped\n")


@pytest.mark.parametrize("threads", ("1", "2", "6"))
def test_check_splits_by_record(stury, records, threads):
    code, out, err = run(stury, records, "check", "--quarantine", "q.ndjson", "--schema", "s.json", "--threads", threads, "--from", "ndjson", "r.ndjson")
    assert code == 5
    assert out.split("\n")[:-1] == [l for i, l in enumerate(lines(WRONG)) if i not in BAD and i not in WRONG]
    quarantined = [json.loads(l) for l in (records / "q.ndjson").read_text().splitlines()]
    assert [q["record"] for q in quarantined] == sorted(i + 1 for i in BAD + WRONG)
    by_record = {q["record"]: q for q in quarantined}
    assert by_record[WRONG[0] + 1]["problem"]["errors"][0]["code"] == "wrong_kind"
    assert by_record[BAD[0] + 1]["problem"]["title"] == "Bad record"
    assert by_record[BAD[1] + 1]["at"].startswith(f"r.ndjson:{BAD[1] + 1}:")
    assert err.endswith(f"stury: {len(BAD)} bad records skipped\n")


def test_check_exit_status_ranks_bad_over_invalid(stury, records):
    (records / "ok.ndjson").write_text('{"i":1}\n{"i":"x"}\n')
    assert run(stury, records, "check", "--skip-bad", "--schema", "s.json", "--from", "ndjson", "ok.ndjson")[0] == 1
    assert run(stury, records, "check", "--skip-bad", "--schema", "s.json", "--from", "ndjson", "ok.ndjson", "r.ndjson")[0] == 5
