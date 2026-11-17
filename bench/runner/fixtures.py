import json
import sys
import tomllib

import pooch

from . import gen
from .layout import BENCH, FIXTURES

# Keywords whose value is one schema, a list of schemas, or a map of names to schemas.
ONE = {"additionalItems", "additionalProperties", "unevaluatedItems", "unevaluatedProperties", "propertyNames", "contains",
       "not", "if", "then", "else", "items", "contentSchema"}
LIST = {"allOf", "anyOf", "oneOf", "prefixItems", "items"}
MAP = {"properties", "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions"}


def table():
    with open(BENCH / "fixtures.toml", "rb") as f:
        return tomllib.load(f)


def drop_formats(schema):
    """Returns SCHEMA without its `format` keywords. Only schema positions are walked: a `const`, `enum`, `default` or
    `examples` value, and the names of a map, are data and stay."""
    if not isinstance(schema, dict):
        return schema
    out = {}
    for k, v in schema.items():
        if k == "format" and isinstance(v, str):
            continue
        if k in LIST and isinstance(v, list):
            v = [drop_formats(s) for s in v]
        elif k in ONE and isinstance(v, dict):
            v = drop_formats(v)
        elif k in MAP and isinstance(v, dict):
            v = {n: drop_formats(s) for n, s in v.items()}
        out[k] = v
    return out


def fetch(group):
    """Downloads the files of GROUP that are missing, each checked against its pinned SHA-256."""
    for pin in table()["download"]:
        if pin["group"] != group:
            continue
        for name, digest in pin["files"].items():
            pooch.retrieve(f"{pin['base']}/{name}", f"sha256:{digest}", fname=name, path=FIXTURES / pin["dir"],
                           downloader=pooch.HTTPDownloader(timeout=120), progressbar=False)
    if group == "schemas":
        for schema in (FIXTURES / "jsonschema-benchmark").glob("*/schema.json"):
            noformat = json.dumps(drop_formats(json.loads(schema.read_bytes())), separators=(",", ":"), ensure_ascii=False)
            (schema.parent / "schema-noformat.json").write_text(noformat)


def generate(names, check):
    """Fetches the corpus the generators read, then writes the fixtures NAMES (all when empty). Returns the process
    status: 1 when a pinned fixture came out with other bytes."""
    unknown = [n for n in names if n not in gen.FIXTURES]
    if unknown:
        sys.exit("unknown fixture: " + ", ".join(unknown))
    fetch("corpus")
    off = gen.write(names or gen.FIXTURES, table()["generated"], check)
    if off:
        print("not the pinned bytes: " + ", ".join(off), file=sys.stderr)
    return 1 if off else 0
