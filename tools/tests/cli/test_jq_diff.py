"""Random filters and inputs run through stury and jq 1.8.2. A case differs when stdout, stderr (stury's `stury:` read as
jq's `jq:`) or the exit status differ, unless docs/cli.md's "Differences from jq" explains it. The cases of a seed are run
in chunks, one test each, and a failing chunk lists its cases, smallest filter first."""

from jq_compare import compare
from jq_grammar import make_cases

CASES = 20000
CHUNK = 200


def pytest_generate_tests(metafunc):
    if "chunk" in metafunc.fixturenames:
        count = metafunc.config.getoption("--cases") or CASES
        chunks = [(seed, n, cases[n:n + CHUNK]) for seed in metafunc.config.getoption("--seed") or [1]
                  for cases in [make_cases(seed, count)] for n in range(0, count, CHUNK)]
        metafunc.parametrize("chunk", chunks, ids=[f"seed{seed}-{n}" for seed, n, _ in chunks])


def test_stury_answers_as_jq(stury, jq_182, chunk):
    differ = sorted((d for d in (compare(stury, jq_182, case) for case in chunk[2]) if d), key=len)
    assert not differ, f"{len(differ)} of {len(chunk[2])} cases differ:\n" + "\n".join(differ)
