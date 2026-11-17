"""The schemas the schema laws run over: the JSON Schema Test Suite's draft 2020-12 groups and the schema fixtures."""

import glob
import json
import os

from capped import ROOT, run_capped

SUITE = os.path.join(ROOT, "core/schema/test/conformance/JSON-Schema-Test-Suite/tests/draft2020-12")
TIMEOUT = 60
# Megabytes one run may hold: the typing's budgets bound it far below.
CAP_MB = 1024


def run(argv, data=None, timeout=TIMEOUT, cap_mb=CAP_MB, **kw):
    p = run_capped(argv, data, timeout, cap_mb=cap_mb, **kw)
    return p.returncode, p.stdout, p.stderr


def suite_schemas():
    out = []
    for path in sorted(glob.glob(f"{SUITE}/*.json")):
        with open(path, "rb") as f:
            for i, group in enumerate(json.load(f)):
                out.append((f"{os.path.basename(path)}#{i}", json.dumps(group["schema"]), None))
    return out


def fixture_schemas(root):
    out = []
    for path in sorted(glob.glob(f"{root}/schema/*.schema.json")):
        data = path.replace(".schema.json", ".ndjson")
        out.append((os.path.relpath(path, root), open(path).read(), data if os.path.exists(data) else None))
    for path in sorted(glob.glob(f"{root}/jsonschema-benchmark/*/schema.json")):
        data = os.path.join(os.path.dirname(path), "instances.jsonl")
        out.append((os.path.relpath(path, root), open(path).read(), data if os.path.exists(data) else None))
    return out
