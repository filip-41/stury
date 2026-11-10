#!/usr/bin/env python3
"""Fetches the files the doc lane reads but does not ship: the public JSON corpus that other parsers' benchmarks
use, and the other libraries' sources. bench/sources.toml pins every file by URL and SHA-256. A download with a
different hash is refused; a file already on disk with the pinned hash is not fetched again.

`schema` fetches the schemas and instances of the check lane (bench/fixtures/jsonschema-benchmark/NAME/) and writes each
schema-noformat.json. `archive` fetches the sources of the schema peers that build from a repository (Blaze). Neither
is part of the default.

    python3 bench/fetch.py [corpus] [source] [schema] [archive]     # default: corpus and source
"""
import hashlib
import io
import json
import os
import sys
import tarfile
import tomllib
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "fixtures", "corpus")
SCHEMAS = os.path.join(HERE, "fixtures", "jsonschema-benchmark")
DEPS = os.path.join(os.path.dirname(HERE), "build", "bench", "deps")
# The most bytes an archive may unpack to.
UNPACK_MAX = 1 << 30


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def download(url, want):
    """Returns the bytes at URL. Exits when their SHA-256 is not WANT."""
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    if sha256(data) != want:
        sys.exit("%s: sha256 %s, pinned %s; refusing it" % (url, sha256(data), want))
    return data


def unpack(data, include, dest, exclude=()):
    """Writes the regular files of the gzip tar DATA that lie under INCLUDE of its one top directory into DEST, except
    those under a directory of EXCLUDE."""
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for member in tar:
            top, _, inside = member.name.partition("/")
            if not member.isfile() or not top or include and not (inside + "/").startswith(include + "/"):
                continue
            if any(inside.startswith(x + "/") for x in exclude):
                continue
            if inside.startswith("/") or ".." in inside.split("/"):
                sys.exit("%s: unsafe path %r" % (dest, member.name))
            total += member.size
            if total > UNPACK_MAX:
                sys.exit("%s: more than %d bytes" % (dest, UNPACK_MAX))
            target = os.path.join(dest, inside[len(include):].lstrip("/"))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(tar.extractfile(member).read())


def fetch_archive(pin):
    dest = os.path.join(DEPS, pin["name"])
    stamp = os.path.join(dest, ".sha256")
    if os.path.exists(stamp) and open(stamp).read() == pin["sha256"]:
        return
    print("archive: %s" % pin["name"], flush=True)
    data = download(pin["url"], pin["sha256"])
    unpack(data, "", dest, pin.get("exclude", ()))
    with open(stamp, "w") as f:
        f.write(pin["sha256"])


# Keywords whose value is one schema, a list of schemas, or a map of names to schemas.
ONE = {"additionalItems", "additionalProperties", "unevaluatedItems", "unevaluatedProperties", "propertyNames", "contains",
       "not", "if", "then", "else", "items", "contentSchema"}
LIST = {"allOf", "anyOf", "oneOf", "prefixItems", "items"}
MAP = {"properties", "patternProperties", "dependentSchemas", "dependencies", "$defs", "definitions"}


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


def write_noformat(name):
    """Writes NAME/schema-noformat.json from schema.json: the schema every peer is given, since the formats
    are annotations in 2019-09 and later and each library asserts a different set."""
    src = os.path.join(SCHEMAS, name, "schema.json")
    with open(src, "rb") as f:
        schema = json.load(f)
    with open(os.path.join(SCHEMAS, name, "schema-noformat.json"), "w") as f:
        json.dump(drop_formats(schema), f, separators=(",", ":"), ensure_ascii=False)


def fetch(pin):
    if pin["kind"] == "archive":
        return fetch_archive(pin)
    base = pin["url"].rsplit("/", 1)[1]
    if pin["kind"] == "schema":
        path = os.path.join(SCHEMAS, pin["name"], pin["file"])
    elif pin["kind"] == "corpus":
        path = os.path.join(CORPUS, pin["name"])
    else:
        path = os.path.join(DEPS, pin["name"], base)
    if os.path.exists(path):
        with open(path, "rb") as f:
            if sha256(f.read()) == pin["sha256"]:
                return
    print("%s: %s %s" % (pin["kind"], pin["name"], pin.get("version") or pin.get("file", "")), flush=True)
    data = download(pin["url"], pin["sha256"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def schema_pins(table):
    """The pins of the table's fixtures: a schema and its instances each."""
    return [{"kind": "schema", "name": row["name"], "file": file, "url": f"{table['url']}/{row['name']}/{file}",
             "sha256": row[key]}
            for row in table["fixtures"] for file, key in (("schema.json", "schema"), ("instances.jsonl", "instances"))]


def main(argv):
    kinds = set(argv) or {"corpus", "source"}
    if kinds - {"corpus", "source", "schema", "archive"}:
        sys.exit(__doc__)
    with open(os.path.join(HERE, "sources.toml"), "rb") as f:
        sources = tomllib.load(f)
    pins = sources["pin"] + schema_pins(sources["schema"])
    for pin in pins:
        if pin["kind"] in kinds:
            fetch(pin)
    if "schema" in kinds:
        for name in sorted({p["name"] for p in pins if p["kind"] == "schema"}):
            write_noformat(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
