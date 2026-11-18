import json
import sys
import time
import tomllib

import pooch
import requests

from . import gen
from .layout import BENCH, FIXTURES

# Keywords whose value is one schema, a list of schemas, or a map of names to schemas.
ONE = {"additionalItems", "additionalProperties", "unevaluatedItems", "unevaluatedProperties", "propertyNames", "contains",
       "not", "if", "then", "else", "items", "contentSchema"}
LIST = {"allOf", "anyOf", "oneOf", "prefixItems", "items"}
MAP = {"properties", "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions"}

ATTEMPTS = 6


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


def retrieve(url, digest, fname, path):
    """Downloads URL to PATH/FNAME unless it is there with SHA-256 DIGEST. An archive that answers 429 or 503 is asked
    again after a wait."""
    for attempt in range(1, ATTEMPTS + 1):
        try:
            pooch.retrieve(url, f"sha256:{digest}", fname=fname, path=path,
                           downloader=pooch.HTTPDownloader(timeout=120), progressbar=False)
            return
        except requests.HTTPError as e:
            if e.response.status_code not in (429, 503) or attempt == ATTEMPTS:
                raise
            time.sleep(30 * attempt)


def fetch(group):
    """Downloads the files of GROUP (all groups when None) that are missing, each checked against its pinned SHA-256, and
    saves one under `save`'s name for it when the pin gives one."""
    for pin in table()["download"]:
        if group not in (None, pin["group"]):
            continue
        for name, digest in pin["files"].items():
            retrieve(f"{pin['base']}/{name}", digest, pin.get("save", {}).get(name, name), FIXTURES / pin["dir"])
    if group in (None, "schemas"):
        for schema in (FIXTURES / "jsonschema-benchmark").glob("*/schema.json"):
            noformat = json.dumps(drop_formats(json.loads(schema.read_bytes())), separators=(",", ":"), ensure_ascii=False)
            (schema.parent / "schema-noformat.json").write_text(noformat)


def generate(names, check):
    """Fetches the downloaded fixtures (only the corpus the generators read when NAMES is given), then writes the
    fixtures NAMES (all when empty). Returns the process
    status: 1 when a pinned fixture came out with other bytes."""
    unknown = [n for n in names if n not in gen.FIXTURES]
    if unknown:
        sys.exit("unknown fixture: " + ", ".join(unknown))
    fetch(None if not names else "corpus")
    off = gen.write(names or gen.FIXTURES, table()["generated"], check)
    if off:
        print("not the pinned bytes: " + ", ".join(off), file=sys.stderr)
    return 1 if off else 0
