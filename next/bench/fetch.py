#!/usr/bin/env python3
"""Fetches the files the doc lane reads but does not ship: the public JSON corpus that other parsers' benchmarks
use, and the other libraries' sources. next/bench/sources.toml pins every file by URL and SHA-256. A download with a
different hash is refused; a file already on disk with the pinned hash is not fetched again.

    python3 next/bench/fetch.py [corpus] [source]     # default: both
"""
import hashlib
import os
import sys
import tomllib
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "fixtures", "corpus")
DEPS = os.path.join(os.path.dirname(HERE), "build", "bench", "deps")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def download(url, want):
    """Returns the bytes at URL. Exits when their SHA-256 is not WANT."""
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
    if os.path.exists(path):
        with open(path, "rb") as f:
            if sha256(f.read()) == pin["sha256"]:
                return
    print("%s: %s %s" % (pin["kind"], pin["name"], pin.get("version", "")), flush=True)
    data = download(pin["url"], pin["sha256"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


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
