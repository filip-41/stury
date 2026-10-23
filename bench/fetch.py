#!/usr/bin/env python3
"""Fetches what the bench reads but does not ship: the public JSON corpus other parsers' benchmarks use, and
the other libraries' sources. Every file is pinned in bench/sources.toml by URL and SHA-256; a download whose
hash differs is refused, and a file already on disk with the pinned hash is not fetched again.

    python3 bench/fetch.py [corpus] [source]     # default: both
"""
import hashlib
import io
import os
import sys
import tarfile
import tomllib
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "fixtures", "corpus")
DEPS = os.path.join(os.path.dirname(HERE), "build", "bench", "deps")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def download(url, want):
    """The bytes at URL, or SystemExit when their hash is not the pinned one."""
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    if sha256(data) != want:
        sys.exit("%s: sha256 %s, pinned %s; refusing it" % (url, sha256(data), want))
    return data


def fetch(pin):
    base = pin["url"].rsplit("/", 1)[1]
    if pin["kind"] == "corpus":
        path = os.path.join(CORPUS, pin["name"])
    else:
        path = os.path.join(DEPS, pin["name"], base)
    # An unpacked archive keeps its hash beside it, so a rerun does not fetch it again.
    stamp = path + ".sha256" if base.endswith(".tar.gz") else path
    if os.path.exists(stamp):
        with open(stamp, "rb") as f:
            have = f.read()
        if (have.decode() if stamp != path else sha256(have)) == pin["sha256"]:
            return
    print("%s: %s %s" % (pin["kind"], pin["name"], pin.get("version", "")), flush=True)
    data = download(pin["url"], pin["sha256"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if stamp == path:
        with open(path, "wb") as f:
            f.write(data)
        return
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        # The top directory (`<repo>-<tag>/`) is dropped, so paths do not name the version.
        members = []
        for m in t.getmembers():
            rest = m.name.partition("/")[2]
            if rest:
                m.name = rest
                members.append(m)
        t.extractall(os.path.dirname(path), members=members, filter="data")
    with open(stamp, "w") as f:
        f.write(pin["sha256"])


def main(argv):
    kinds = set(argv) or {"corpus", "source"}
    if kinds - {"corpus", "source"}:
        sys.exit(__doc__)
    with open(os.path.join(HERE, "sources.toml"), "rb") as f:
        pins = tomllib.load(f)["pin"]
    for pin in pins:
        if pin["kind"] in kinds:
            fetch(pin)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
