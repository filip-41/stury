#!/usr/bin/env python3
"""Write the tables/idna*.bin blobs format_idna.odin loads: what IDNA2008 allows in a label, and the mapping UTS 46 gives a name.

All of it is one Unicode version, 12.0.0, the version IANA's IDNA tables registry is based on:
  IANA idna-tables-properties.csv: each code point's derived property (PVALID, CONTEXTJ, CONTEXTO, DISALLOWED or
    UNASSIGNED) under RFC 5892, from https://www.iana.org/assignments/idna-tables-12.0.0/
  Unicode Character Database, https://www.unicode.org/Public/12.0.0/ucd/extracted/: DerivedJoiningType.txt (joining
    type, for the zero width non-joiner rule), DerivedBidiClass.txt (bidi class, for RFC 5893) and
    DerivedCombiningClass.txt (the virama, class 9, a zero width joiner may follow).
  UTS 46, https://www.unicode.org/Public/idna/12.0.0/IdnaMappingTable.txt: the mapping step, with its
    disallowed_STD3 statuses read as disallowed and its deviations kept.

Run from the repository root:
    python3 core/rules/idna_tables.py
"""
import csv
import io
import pathlib
import struct
import urllib.request

BLOBS = pathlib.Path(__file__).with_name("tables")
UNICODE = "12.0.0"
IANA = f"https://www.iana.org/assignments/idna-tables-{UNICODE}/idna-tables-properties.csv"
UCD = f"https://www.unicode.org/Public/{UNICODE}/ucd/extracted/"
MAPPING = f"https://www.unicode.org/Public/idna/{UNICODE}/IdnaMappingTable.txt"

# The orders of the enums in format_idna.odin.
DERIVED = ["DISALLOWED", "PVALID", "CONTEXTJ", "CONTEXTO"]
JOINING = ["U", "L", "R", "D", "T", "C"]
BIDI = ["L", "R", "AL", "AN", "EN", "ES", "CS", "ET", "ON", "BN", "NSM"]
VIRAMA = 9
# The mapping kinds: a code point kept, dropped, refused, moved by a fixed distance, or replaced by a string.
KEEP, DROP, REFUSE, SHIFT, STRING = range(5)
LAST = 0x10FFFF


def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "stury"})).read().decode()


def span(field):
    lo, _, hi = field.strip().replace("-", "..").partition("..")
    return int(lo, 16), int(hi or lo, 16)


def ucd_values(name):
    """The value each code point of an extracted Derived file lists, as {code point: field after the first ;}."""
    values = {}
    for line in fetch(UCD + name).splitlines():
        fields = line.split("#")[0].split(";")
        if len(fields) > 1:
            lo, hi = span(fields[0])
            for c in range(lo, hi + 1):
                values[c] = fields[1].strip()
    return values


def runs(values):
    """[(start, value)] where the value changes, from the list of one value a code point."""
    return [(c, v) for c, v in enumerate(values) if c == 0 or v != values[c - 1]]


def properties():
    derived = [0] * (LAST + 1)
    for row in csv.DictReader(io.StringIO(fetch(IANA))):
        lo, hi = span(row["Codepoint"])
        for c in range(lo, hi + 1):
            derived[c] = DERIVED.index(row["Property"]) if row["Property"] in DERIVED else 0
    joining, bidi, ccc = ucd_values("DerivedJoiningType.txt"), ucd_values("DerivedBidiClass.txt"), ucd_values("DerivedCombiningClass.txt")
    packed = []
    for c in range(LAST + 1):
        if not derived[c]:
            packed.append(0)
            continue
        assert bidi[c] in BIDI, f"{c:X} has bidi class {bidi[c]}"
        packed.append(derived[c] | JOINING.index(joining.get(c, "U")) << 2 | BIDI.index(bidi[c]) << 5
                      | (ccc.get(c) == str(VIRAMA)) << 9)
    # One u32 a run: `start << 10 | derived | joining << 2 | bidi << 5 | virama << 9`.
    return struct.pack("<%dI" % len(runs(packed)), *(c << 10 | v for c, v in runs(packed)))


def mapping():
    kinds = [(KEEP, 0)] * (LAST + 1)
    pool, at = [], {}
    for line in fetch(MAPPING).splitlines():
        fields = [f.strip() for f in line.split("#")[0].split(";")]
        if len(fields) < 2 or not fields[0]:
            continue
        lo, hi = span(fields[0])
        status = fields[1]
        if status in ("valid", "deviation"):
            kind = (KEEP, 0)
        elif status == "ignored":
            kind = (DROP, 0)
        elif status.startswith("disallowed"):
            kind = (REFUSE, 0)
        else:
            assert status == "mapped"
            target = [int(x, 16) for x in fields[2].split()]
            assert 0 < len(target) < 32
            kind = None
        for c in range(lo, hi + 1):
            if kind:
                kinds[c] = kind
            elif len(target) == 1:
                kinds[c] = (SHIFT, (target[0] - c) & 0xFFFFFFFF)
            else:
                key = tuple(target)
                if key not in at:
                    at[key] = len(pool)
                    pool += target
                kinds[c] = (STRING, at[key] << 5 | len(target))
    assert len(pool) < 1 << 27 and max(len(k) for k in at) < 32
    # One u64 a run: `start << 40 | kind << 32 | payload`, the payload a shift or a string's pool offset << 5 | length.
    entries = [c << 40 | k << 32 | p for c, (k, p) in runs(kinds)]
    print(f"longest mapping: {max(len(k) for k in at)} code points")
    return struct.pack("<%dQ" % len(entries), *entries), struct.pack("<%dI" % len(pool), *pool)


def main():
    BLOBS.mkdir(exist_ok=True)
    maps, pool = mapping()
    for name, data in {"idna": properties(), "idna_map": maps, "idna_pool": pool}.items():
        (BLOBS / f"{name}.bin").write_bytes(data)
        print(f"{name}.bin: {len(data)} bytes")


if __name__ == "__main__":
    main()
