"""Random regular expressions and texts run through stury and jq 1.8.2 (Oniguruma), as test_jq_diff.py runs filters."""

from jq_compare import compare
from regex_grammar import make_cases, skipped

CASES = 20000
CHUNK = 200


def pytest_generate_tests(metafunc):
    if "chunk" in metafunc.fixturenames:
        count = metafunc.config.getoption("--cases") or CASES
        chunks = [(seed, n, [c for c in cases[n:n + CHUNK] if not skipped(c)]) for seed in metafunc.config.getoption("--seed") or [1]
                  for cases in [make_cases(seed, count)] for n in range(0, count, CHUNK)]
        metafunc.parametrize("chunk", chunks, ids=[f"seed{seed}-{n}" for seed, n, _ in chunks])


def test_stury_regex_answers_as_jq(stury, jq_182, chunk):
    differ = sorted((d for d in (compare(stury, jq_182, case) for case in chunk[2]) if d), key=len)
    assert not differ, f"{len(differ)} of {len(chunk[2])} cases differ:\n" + "\n".join(differ)
