#!/usr/bin/env python3
"""Fetches the W3C XML Conformance Test Suite (xmlts20130923) and selects the cases of XML 1.0 it holds.

    python3 xml/test/conformance/fetch.py [PATH/TO/xmlts20130923.tar.gz]

Downloads the archive unless a path is given, giving up after `TIMEOUT` seconds without data, checks its SHA-256
against `DIGEST`, and writes the selected documents and their canonical forms to `files/` beside this script (not
tracked: the suite's licenses do not let this repository carry the files) and the list to `cases.tsv`. A case is taken when it applies to the Fifth Edition of XML 1.0 (the base
recommendation) or to Namespaces in XML 1.0. `cases.tsv` has one row per case: the type (`valid`, `invalid`, `not-wf`,
or `not-ns` for a case the suite marks as well formed but not namespace conforming), the path under `files/`, the
external entities the case refers to (`none`, `general`, `parameter` or `both`), and the path of its canonical form, or
nothing for a case with none. It is tracked, and a run that selects other cases fails.
"""
import hashlib
import os
import posixpath
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request

DIGEST = "9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f"
SOURCE = "https://www.w3.org/XML/Test/xmlts20130923.tar.gz"
TIMEOUT = 60

INDEXES = [
    "xmltest/xmltest.xml",
    "sun/sun-valid.xml",
    "sun/sun-invalid.xml",
    "sun/sun-not-wf.xml",
    "oasis/oasis.xml",
    "ibm/ibm_oasis_valid.xml",
    "ibm/ibm_oasis_invalid.xml",
    "ibm/ibm_oasis_not-wf.xml",
    "japanese/japanese.xml",
    "eduni/errata-2e/errata2e.xml",
    "eduni/errata-3e/errata3e.xml",
    "eduni/errata-4e/errata4e.xml",
    "eduni/misc/ht-bh.xml",
    "eduni/namespaces/1.0/rmt-ns10.xml",
    "eduni/namespaces/errata-1e/errata1e.xml",
]

TEST = re.compile(r"<TEST\s([^>]*)>", re.S)
ATTR = re.compile(r"""([A-Za-z:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')""")


def copy(root: str, out: str, path: str) -> None:
    dest = os.path.join(out, path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copyfile(os.path.join(root, path), dest)


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "files")
    with tempfile.TemporaryDirectory() as tmp:
        archive = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tmp, "xmlts.tar.gz")
        if len(sys.argv) == 1:
            try:
                with urllib.request.urlopen(SOURCE, timeout=TIMEOUT) as r, open(archive, "wb") as f:
                    shutil.copyfileobj(r, f)
            except OSError as e:
                sys.exit(f"cannot fetch {SOURCE}: {e}")
        with open(archive, "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != DIGEST:
                sys.exit("the archive is not xmlts20130923.tar.gz")
        with tarfile.open(archive) as t:
            t.extractall(tmp, filter="data")
        root = os.path.join(tmp, "xmlconf")
        # The documents are written apart and moved to `files/` only once the selection matches, so a `files/` that
        # exists is whole.
        staged = os.path.join(tmp, "files")
        rows = []
        for index in INDEXES:
            base = os.path.dirname(index)
            with open(os.path.join(root, index), encoding="utf-8", errors="replace") as f:
                text = f.read()
            for m in TEST.finditer(text):
                a = {k: v or w for k, v, w in ATTR.findall(m.group(1))}
                kind = a.get("TYPE")
                if kind not in ("valid", "invalid", "not-wf"):
                    continue
                if a.get("VERSION") == "1.1" or not (a.get("RECOMMENDATION", "XML1.0") == "XML1.0" or a.get("RECOMMENDATION", "").startswith("NS1.0")):
                    continue
                if "EDITION" in a and "5" not in a["EDITION"].split():
                    continue
                path = posixpath.normpath(posixpath.join(base, a["URI"]))
                if a.get("NAMESPACE") == "no":
                    kind = "not-ns"
                canonical = posixpath.normpath(posixpath.join(base, a["OUTPUT"])) if a.get("OUTPUT") else ""
                copy(root, staged, path)
                if canonical:
                    copy(root, staged, canonical)
                rows.append((kind, path, a.get("ENTITIES", "none"), canonical))
        rows.sort(key=lambda r: r[1])
        listing = "".join("\t".join(r) + "\n" for r in rows)
        index = os.path.join(here, "cases.tsv")
        if os.path.exists(index):
            with open(index, newline="") as f:
                if f.read() != listing:
                    sys.exit("the selection differs from cases.tsv")
        else:
            with open(index, "w", newline="") as f:
                f.write(listing)
        shutil.rmtree(out, ignore_errors=True)
        shutil.move(staged, out)
    print(len(rows), "cases from", SOURCE)


if __name__ == "__main__":
    main()
