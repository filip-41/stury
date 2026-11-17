import os
import subprocess

import pytest

from capped import ROOT, fixtures_dir


def pytest_addoption(parser):
    parser.addoption("--stury", default=os.path.join(ROOT, "build", "stury"), help="the binary the cli tests run")
    parser.addoption("--odin", default=os.environ.get("ODIN", "odin"), help="the compiler of the tests that build their own binaries")
    parser.addoption("--seed", type=int, action="append", help="a differential's seed, repeatable, each differential's own by default")
    parser.addoption("--cases", type=int, help="how many random cases a differential makes, its own count by default")
    parser.addoption("--jq", default="jq", help="jq 1.8.2, the reference of the cli.tsv recording and of the differentials")
    parser.addoption("--bench-fixtures", default=fixtures_dir(), help="bench/fixtures, the main checkout's by default, where the schema laws read the fixture schemas")
    parser.addoption("--samples", type=int, default=12, help="the values the schema laws sample from each schema")
    parser.addoption("--batch", type=int, default=120, help="the packages one driver of the gen law compiles")
    parser.addoption("--diff", action="store_true", help="also run the jq suite's cases through jq 1.8.2 and require the same answer")


@pytest.fixture(scope="session")
def stury(request):
    return os.path.abspath(request.config.getoption("--stury"))


@pytest.fixture(scope="session")
def odin(request):
    return request.config.getoption("--odin")


@pytest.fixture(scope="session")
def jq(request):
    return request.config.getoption("--jq")


def jq_is_1_8_2(jq):
    try:
        return subprocess.run([jq, "--version"], capture_output=True, text=True).stdout.strip() == "jq-1.8.2"
    except FileNotFoundError:
        return False


@pytest.fixture(scope="session")
def jq_182(jq):
    if not jq_is_1_8_2(jq):
        pytest.skip(f"no jq 1.8.2 as {jq!r}")
    return jq


def pytest_configure(config):
    if config.getoption("--diff") and not jq_is_1_8_2(config.getoption("--jq")):
        raise pytest.UsageError("--diff needs jq 1.8.2 on PATH, or as --jq")


def pytest_generate_tests(metafunc):
    """A test that takes `seed` runs once for each --seed, or for the module's DEFAULT_SEEDS."""
    if "seed" in metafunc.fixturenames:
        seeds = metafunc.config.getoption("--seed") or getattr(metafunc.module, "DEFAULT_SEEDS", [1])
        metafunc.parametrize("seed", seeds, ids=lambda s: f"seed{s}")

