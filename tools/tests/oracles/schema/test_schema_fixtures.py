"""stury check against jsonschema on the schema lane's fixtures: the verdict of each of the first INSTANCES instances of
a fixture must be the same. The fixtures are the rows of bench/lanes/schema/lane.toml, read from --bench-fixtures. The
other libraries' verdicts are the lane's own agreement check.

The suite test holds jsonschema itself to the expected verdicts of the vendored JSON-Schema-Test-Suite, so a difference
above is stury's. A case whose schema jsonschema cannot compile or resolve is left out.
"""

import glob
import itertools
import json
import os
import tomllib

import jsonschema
import pytest
import referencing
import referencing.jsonschema

from capped import ROOT, run_capped

INSTANCES = 1000
SUITE = os.path.join(ROOT, "core", "schema", "test", "conformance", "JSON-Schema-Test-Suite", "tests")
REMOTES = os.path.join(os.path.dirname(SUITE), "remotes")
BASE = "http://localhost:1234/"
DRAFTS = {"draft4": jsonschema.Draft4Validator, "draft6": jsonschema.Draft6Validator, "draft7": jsonschema.Draft7Validator,
          "draft2019-09": jsonschema.Draft201909Validator, "draft2020-12": jsonschema.Draft202012Validator}

# Cases jsonschema answers against the suite: it takes a metaschema's missing validation vocabulary as present, and
# takes an unevaluatedProperties beside a non-boolean additionalProperties of draft 2019-09 as reaching its members.
KNOWN_WRONG = {
    "vocabulary.json: schema that uses custom metaschema with with no validation vocabulary: no validation: invalid number, but it still validates",
    "unevaluatedProperties.json: unevaluatedProperties with adjacent non-bool additionalProperties: with additional properties",
}

with open(os.path.join(ROOT, "bench", "lanes", "schema", "lane.toml"), "rb") as f:
    ROWS = tomllib.load(f)["group"][0]["rows"]


def fixture_path(root, name):
    for directory in (root, os.path.join(root, "corpus")):
        if os.path.exists(os.path.join(directory, name)):
            return os.path.join(directory, name)
    pytest.skip(f"no fixture {name} in {root}")


@pytest.mark.parametrize("row", ROWS, ids=[r["label"] for r in ROWS])
def test_check_gives_jsonschema_verdicts(stury, row, request, tmp_path):
    root = request.config.getoption("--bench-fixtures")
    schema_path, instances_path = fixture_path(root, row["schema"]), fixture_path(root, row["file"])
    with open(schema_path, "rb") as f:
        schema = json.load(f)
    lines = instances_path.endswith((".jsonl", ".ndjson"))
    with open(instances_path, "rb") as f:
        texts = [t.rstrip(b"\r\n") for t in itertools.islice((l for l in f if l.strip()), INSTANCES)] if lines else [f.read()]
    validator = jsonschema.validators.validator_for(schema)(schema)
    want = [validator.is_valid(json.loads(t)) for t in texts]
    path = str(tmp_path / ("instances.ndjson" if lines else "instance.json"))
    with open(path, "wb") as f:
        f.write(b"\n".join(texts) + b"\n" if lines else texts[0])
    ran = run_capped([stury, "check", "--schema", schema_path, path], None, 120, cap_mb=2048)
    if ran.returncode == 2 and b"Schema is refused" in ran.stderr:
        pytest.skip(ran.stderr.decode(errors="replace").strip()[:300])
    assert ran.returncode in (0, 1), f"stury check exits {ran.returncode}: {ran.stderr.decode(errors='replace')[:300]}"
    failed = {int(m.split(b":")[1]) - 1 for m in ran.stderr.splitlines() if m.startswith(path.encode() + b":") and m.split(b":")[1].isdigit()}
    got = [i not in failed for i in range(len(texts))] if lines else [ran.returncode == 0]
    differ = [i for i, (a, b) in enumerate(zip(want, got)) if a != b]
    assert not differ, f"{len(differ)} of {len(texts)} instances differ, the first at {differ[0]}: jsonschema {want[differ[0]]}, stury {got[differ[0]]}"


def retrieve(uri):
    """The suite's remote documents, which its runners serve on localhost:1234."""
    with open(os.path.join(REMOTES, uri.removeprefix(BASE)), "rb") as f:
        return referencing.Resource.from_contents(json.load(f), default_specification=referencing.jsonschema.DRAFT202012)


@pytest.mark.parametrize("draft", DRAFTS)
def test_jsonschema_gives_the_suite_verdicts(draft):
    if not os.path.isdir(os.path.join(SUITE, draft)):
        pytest.skip(f"no {draft} in the vendored suite")
    wrong = []
    for path in sorted(glob.glob(os.path.join(SUITE, draft, "*.json"))):
        with open(path, "rb") as f:
            groups = json.load(f)
        for group in groups:
            try:
                validator = DRAFTS[draft](group["schema"], registry=referencing.Registry(retrieve=retrieve))
            except Exception:
                continue
            for test in group["tests"]:
                try:
                    got = validator.is_valid(test["data"])
                except Exception:
                    continue
                if got != test["valid"]:
                    wrong.append(f"{os.path.basename(path)}: {group['description']}: {test['description']}")
    wrong = [w for w in wrong if w not in KNOWN_WRONG]
    assert not wrong, f"{len(wrong)} cases differ from the suite:\n" + "\n".join(wrong[:15])
