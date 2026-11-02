#!/usr/bin/env python3
"""Writes the doc lane fixtures to next/bench/fixtures/<name> and prints each one's SHA-256.

The output is deterministic (no clock, no network, only seeded PRNGs), so it matches manifest.toml's [fixtures]
hashes. Most generators use CPython's `random` module; the hashes were checked on CPython 3.14. With no NAME every
fixture is written. After a generator change, paste the printed hashes into the manifest.

    python3 next/bench/gen.py [NAME...] [--check]
"""

import argparse
import csv
import hashlib
import io
import json
import os
import random
import sys
import tomllib

MIB = 1024 * 1024
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")


def gen_nested_json(target: int) -> bytes:
    rnd = random.Random(4242)
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        rec = {
            "id": rnd.randrange(1 << 40),
            "name": "".join(rnd.choice("abcdefghij") for _ in range(24)),
            "tags": [rnd.randrange(1000) for _ in range(6)],
            "nested": {"a": [rnd.random() for _ in range(4)],
                       "b": {"c": rnd.randrange(1 << 20)}},
            "ok": bool(rnd.getrandbits(1)),
        }
        if not first:
            out += b","
        out += json.dumps(rec, separators=(",", ":")).encode()
        first = False
    out += b"]"
    return bytes(out)


def gen_escape_json(target: int) -> bytes:
    """Returns an escape- and number-heavy array. It is the only fixture whose content
    `.Structural` does not check, so `.Strict` and `.Structural` differ on it."""
    rnd = random.Random(777)
    escapes = ['\\"', '\\\\', '\\/', '\\b', '\\f', '\\n', '\\r', '\\t',
               '\\u00e9', '\\u0022', '\\ud83d\\ude00', '\\u0000']
    num_templates = ['-0.0', '1.5e-244', '2.25e+300', '-123.456e-78',
                     '123456789012345678901234567890', '0.30000000000000004',
                     '1000000', '-7']
    out = bytearray(b'[')
    first = True
    i = 0
    while len(out) < target:
        n_esc = rnd.randrange(4, 14)
        s = ''.join(rnd.choice(escapes) + 'ab' for _ in range(n_esc))
        num = rnd.choice(num_templates)
        depth = rnd.randrange(0, 3)
        rec = '{"k\\u0041%d":"%s","n":%s,"t":%s' % (i, s, num,
              'true' if rnd.getrandbits(1) else 'false')
        for d in range(depth):
            rec += ',"nest%d":{"a":[%s,%s]}' % (d, num, 'null')
        rec += '}'
        if not first:
            out += b','
        out += rec.encode()
        first = False
        i += 1
    out += b']'
    data = bytes(out)
    json.loads(data)  # must be strictly valid; generation bug otherwise
    return data


def gen_longtext_json(target: int) -> bytes:
    """Returns an array of KB-scale strings, for the long-string path (32 bytes or more)."""
    rnd = random.Random(20240)
    words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur",
             "adipiscing", "elit", "sed", "do", "eiusmod", "tempor"]
    out = bytearray(b'[')
    first = True
    while len(out) < target:
        paras = []
        for _ in range(rnd.randrange(2, 5)):
            paras.append(' '.join(rnd.choice(words) for _ in range(rnd.randrange(200, 500))))
        rec = {"id": rnd.randrange(1 << 40), "body": "\\n\\n".join(paras),
               "tags": ["t%d" % rnd.randrange(100) for _ in range(4)]}
        if not first:
            out += b','
        out += json.dumps(rec, separators=(",", ":")).encode()
        first = False
    out += b']'
    data = bytes(out)
    json.loads(data)
    return data


def gen_utf8_json(target: int) -> bytes:
    """Returns gen_longtext_json's shape with non-ASCII text; longtext.json is its
    ASCII control. Every strictness level validates wire UTF-8, and the ASCII
    fixtures never reach that path. Characters are mixed 2-, 3- and 4-byte."""
    rnd = random.Random(20241001)
    pools = [
        "áéíóúàèìòùâêîôûäëïöüñç",  # 2-byte Latin
        "αβγδεζηθικλμνξοπρστυφχψ",  # 2-byte Greek
        "中文日本語漢字仮名文字",  # 3-byte CJK
        "😀🎉🚀🔥✨🌈🍕🎸🐙🌍",  # 4-byte emoji
    ]
    out = bytearray(b'[')
    first = True
    while len(out) < target:
        paras = []
        for _ in range(rnd.randrange(2, 5)):
            pool = rnd.choice(pools)
            paras.append(' '.join(rnd.choice(pool) * rnd.randrange(1, 4)
                                  for _ in range(rnd.randrange(200, 500))))
        rec = {"id": rnd.randrange(1 << 40), "body": "\n\n".join(paras),
               "tags": [rnd.choice(pools)[:3] for _ in range(4)]}
        if not first:
            out += b','
        out += json.dumps(rec, separators=(",", ":"),
                          ensure_ascii=False).encode('utf-8')
        first = False
    out += b']'
    data = bytes(out)
    json.loads(data.decode('utf-8'))  # must be strictly valid UTF-8 JSON
    return data


def gen_wide_json(target: int) -> bytes:
    """Returns one object with tens of thousands of keys, for reading 2 of N keys."""
    rnd = random.Random(31339)
    out = bytearray(b'{')
    i = 0
    while len(out) < target:
        if i > 0:
            out += b','
        out += ('"field%06d":%d' % (i, rnd.randrange(1 << 31))).encode()
        i += 1
    out += b'}'
    data = bytes(out)
    json.loads(data)
    return data


def gen_pretty_json(target: int) -> bytes:
    """Returns a pretty-printed array of records (indent=2, ~45% whitespace bytes)."""
    rnd = random.Random(5150)
    recs = []
    size = 0
    while size < target:
        rec = {"id": rnd.randrange(1 << 40),
               "name": "n%08d" % rnd.randrange(100000000),
               "v": rnd.randrange(1 << 31),
               "flag": bool(rnd.getrandbits(1))}
        recs.append(rec)
        size += len(json.dumps(rec, separators=(",", ":")))
    data = json.dumps(recs, indent=2).encode()
    json.loads(data)
    return data


class _Lcg:
    """64-bit LCG (Knuth's MMIX constants), so the fixtures drawn from it do not depend on Python's `random`."""

    def __init__(self, seed: int) -> None:
        self.s = seed & 0xFFFFFFFFFFFFFFFF

    def next(self) -> int:
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        return self.s >> 11

    def below(self, n: int) -> int:
        return self.next() % n

    def pick(self, xs):
        return xs[self.below(len(xs))]


def gen_deep_json(target: int) -> bytes:
    """Returns an array of 256-deep array chains. The other fixtures nest at most
    8 deep. 256 is under the 1024 depth cap
    and under CPython's recursion limit for the self-check."""
    rnd = random.Random(20261010)
    depth = 256
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        leaf = str(rnd.randrange(1 << 31))
        chain = "[" * depth + leaf + "]" * depth
        if not first:
            out += b","
        out += chain.encode()
        first = False
    out += b"]"
    data = bytes(out)
    json.loads(data)
    return data


def gen_table_csv(target: int, delimiter: str = ",") -> bytes:
    """Returns a numeric table (~70 B a row, unquoted) of 4 integers, 4 decimals, a bool and a 3-letter code."""
    rng = _Lcg(0xC5F0001)
    out = [delimiter.join(["id", "ts", "lat", "lon", "qty", "price", "score", "ok", "code"]) + "\n"]
    size, i = len(out[0]), 0
    while size < target:
        row = delimiter.join([
            str(i), str(1790000000 + i * 3 + rng.below(3)),
            "%.5f" % ((rng.below(18000000) - 9000000) / 1e5), "%.5f" % ((rng.below(36000000) - 18000000) / 1e5),
            str(rng.below(10000)), "%d.%02d" % (rng.below(100000), rng.below(100)),
            "%.4f" % (rng.below(10000000) / 1e4), "true" if rng.below(2) else "false",
            "".join(chr(65 + rng.below(26)) for _ in range(3))]) + "\n"
        out.append(row)
        size += len(row)
        i += 1
    data = "".join(out).encode("ascii")
    return _check_csv(data, delimiter, csv.QUOTE_NONE if delimiter == "\t" else csv.QUOTE_MINIMAL, 9)


def gen_wide_csv(target: int) -> bytes:
    """Returns a 200-column table (~1.2 KB a row) of integers, with every fifth column a 2-decimal number."""
    rng = _Lcg(0xC5F0003)
    out = [",".join("c%03d" % c for c in range(200)) + "\n"]
    size = len(out[0])
    while size < target:
        row = ",".join("%d.%02d" % (rng.below(1000), rng.below(100)) if c % 5 == 4 else str(rng.below(100000))
                       for c in range(200)) + "\n"
        out.append(row)
        size += len(row)
    return _check_csv("".join(out).encode("ascii"), ",", csv.QUOTE_MINIMAL, 200)


def _check_csv(data: bytes, delimiter: str, quoting: int, columns: int) -> bytes:
    """Returns DATA when it parses strictly into rows all COLUMNS wide; asserts otherwise."""
    rows = list(csv.reader(io.StringIO(data.decode("utf-8"), newline=""), delimiter=delimiter,
                           quoting=quoting, strict=True))
    assert rows and all(len(r) == columns for r in rows), "ragged or empty csv fixture"
    return data


def gen_logs_json(target: int) -> bytes:
    """Returns `{"logs":[{...}, ...]}`, the common array-of-records shape: flat 8-member log records
    (~227 B each), ASCII, no escapes, messages of 20-60 bytes."""
    rng = _Lcg(0x5EED10C5)
    out = bytearray(b'{"logs":[')
    first = True
    i = 0
    while len(out) < target:
        if not first:
            out += b","
        first = False
        i += 1
        words = " ".join(rng.pick(_LOG_WORDS) for _ in range(6 + rng.below(6)))
        msg = "%s %s %s" % (rng.pick(_LOG_SERVICES), words, i)
        rec = (
            '{"ts":"2026-10-03T%02d:%02d:%02d.%03dZ",'
            '"level":"%s","service":"%s","msg":"%s",'
            '"status":%d,"bytes":%d,"duration_ms":%d.%03d,"id":"req-%08x"}'
            % (
                rng.below(24), rng.below(60), rng.below(60), rng.below(1000),
                rng.pick(_LOG_LEVELS), rng.pick(_LOG_SERVICES), msg,
                200 + rng.below(300),
                rng.below(200000),
                rng.below(500), rng.below(1000),
                rng.next() & 0xFFFFFFFF,
            )
        )
        out += rec.encode("ascii")
    out += b']}'
    data = bytes(out)
    json.loads(data.decode("ascii"))
    return data


def gen_logs_dialect(target: int, json5: bool) -> bytes:
    """Returns `gen_logs_json`'s records one per line in a dialect, each followed by a trailing comma. JSONC puts a
    line comment before every fourth record and a block comment after every sixteenth. JSON5 leaves keys unquoted,
    quotes strings with `'`, writes `status` in hex and `bytes` with a leading `+`."""
    rng = _Lcg(0x5EED10C5)
    q = "'" if json5 else '"'
    out = bytearray(b"{\n  logs: [\n" if json5 else b'{"logs":[\n')
    i = 0
    while len(out) < target:
        i += 1
        words = " ".join(rng.pick(_LOG_WORDS) for _ in range(6 + rng.below(6)))
        msg = "%s %s %s" % (rng.pick(_LOG_SERVICES), words, i)
        fields = [
            ("ts", "%s2026-10-03T%02d:%02d:%02d.%03dZ%s" % (q, rng.below(24), rng.below(60), rng.below(60), rng.below(1000), q)),
            ("level", q + rng.pick(_LOG_LEVELS) + q),
            ("service", q + rng.pick(_LOG_SERVICES) + q),
            ("msg", q + msg + q),
        ]
        status, size = 200 + rng.below(300), rng.below(200000)
        fields.append(("status", "0x%x" % status if json5 else "%d" % status))
        fields.append(("bytes", "+%d" % size if json5 else "%d" % size))
        fields.append(("duration_ms", "%d.%03d" % (rng.below(500), rng.below(1000))))
        fields.append(("id", "%sreq-%08x%s" % (q, rng.next() & 0xFFFFFFFF, q)))
        if json5:
            line = "    { %s },\n" % ", ".join("%s: %s" % kv for kv in fields)
        else:
            line = "{%s},\n" % ",".join('"%s":%s' % kv for kv in fields)
            if i % 4 == 1:
                out += b"// batch %d\n" % (i // 4)
        out += line.encode("ascii")
        if not json5 and i % 16 == 0:
            out += b"/* checkpoint %d */\n" % (i // 16)
    out += b"  ],\n}\n" if json5 else b"]}\n"
    return bytes(out)


def gen_documents_json(target: int) -> bytes:
    """Returns documents with structure and no period. Each document draws its own
    field->class binding, so values cluster as in a real payload while the class
    stream stays aperiodic. Nesting depth 1..8, string body lengths covering every
    value in 8..23, ~20% escaped strings."""
    rnd = random.Random(20261022)
    key_pool = list(_DOC_KEY_POOL)
    bands = ([0, 1, 2, 3, 4, 5, 6, 7] + list(range(8, 24)) +
             [24, 26, 31, 33, 40, 55, 64, 96, 128])

    def pick_class(w):
        """Returns a class index drawn from the weight vector W."""
        r = rnd.random() * sum(w)
        acc = 0.0
        for i, wi in enumerate(w):
            acc += wi
            if r <= acc:
                return i
        return len(w) - 1

    def schema():
        """Returns one document's field->class binding, shared by every object in
        it. It is drawn per document because one global binding would make the
        class stream periodic, like nested.json's."""
        w = [rnd.random() + 0.12 for _ in range(5)]
        s = sum(w)
        w = [x / s for x in w]
        return w, dict((k, pick_class(w)) for k in key_pool)

    def scalar(cls):
        if cls == 0:
            return _num_token(rnd, 1, 9, frac_p=0.35, exp_p=0.06, skew=0.8)
        if cls == 1:
            return _wire_string(rnd, rnd.choice(bands), 0.20)
        if cls == 2:
            return rnd.choice(["true", "false"])
        if cls == 3:
            return "null"
        return _wire_string(rnd, rnd.choice(bands), 0.20)

    def doc(depth, w, s):
        n = rnd.randrange(2, 11)
        members = []
        for k in rnd.sample(key_pool, n):
            if depth < 8 and rnd.random() < 0.22:
                members.append('"%s":%s' % (k, nested(depth + 1, w, s)))
                continue
            # 25% of members ignore the binding, as optional fields do in a real payload.
            cls = s[k] if rnd.random() < 0.75 else pick_class(w)
            members.append('"%s":%s' % (k, scalar(cls)))
        return "{" + ",".join(members) + "}"

    def nested(depth, w, s):
        n = rnd.randrange(1, 6)
        if rnd.random() < 0.5:
            return "[" + ",".join(scalar(pick_class(w)) for _ in range(n)) + "]"
        return doc(depth, w, s)

    out = bytearray(b"[")
    first = True
    while len(out) < target:
        if not first:
            out += b","
        w, s = schema()
        out += doc(1, w, s).encode()
        first = False
    out += b"]"
    data = bytes(out)
    json.loads(data)
    return data


def _wire_string(rnd, want, escape_p):
    """Returns a JSON string whose decoded body is WANT characters, a share
    ESCAPE_P of them spelled as escapes."""
    parts = ['"']
    got = 0
    while got < want:
        if escape_p and rnd.random() < escape_p:
            parts.append(rnd.choice(_WIRE_ESCAPES))
            got += 1
            continue
        run = min(want - got, rnd.randrange(1, 5))
        parts.append("".join(rnd.choice(_WIRE_PLAIN) for _ in range(run)))
        got += run
    parts.append('"')
    return "".join(parts)


def _num_token(rnd, sig_lo, sig_hi, frac_p=0.0, exp_p=0.0, skew=1.0):
    """Returns a JSON number with SIG_LO..SIG_HI significant digits. A share
    FRAC_P of tokens are fractional and EXP_P carry an exponent inside
    binary64's range, so no token is refused."""
    span = sig_hi - sig_lo + 1
    sig = sig_lo + min(span - 1, int((rnd.random() ** skew) * span))
    digs = str(rnd.randrange(1, 10)) + "".join(
        str(rnd.randrange(10)) for _ in range(sig - 1))
    if rnd.random() < exp_p:
        e = rnd.randrange(-290, 291)
        body = digs[0] + "." + digs[1:] if sig > 1 else digs
        return "%se%s%d" % (body, "+" if e >= 0 else "-", abs(e))
    if rnd.random() < frac_p:
        if sig == 1:
            return "0." + digs
        # Half are `0.x`, since a leading zero takes its own decoder branch.
        if rnd.randrange(2):
            return "0." + digs
        return digs[0] + "." + digs[1:]
    return digs


_LOG_LEVELS = ["debug", "info", "warn", "error", "trace"]
_LOG_SERVICES = ["checkout", "cart", "auth", "search", "shipping", "payments", "inventory",
                 "profile"]
_LOG_WORDS = [
    "request", "completed", "upstream", "timeout", "retry", "cache", "miss",
    "database", "query", "index", "latency", "budget", "exceeded", "accepted",
    "rejected", "connection", "pool", "refused", "warm", "cold", "shard",
    "replica", "leader", "election", "backpressure", "dropped", "flushed",
    "batch", "commit", "rollback", "deadline", "cancelled", "handshake",
]


_WIRE_ESCAPES = ['\\"', '\\\\', '\\n', '\\r', '\\t', '\\b', '\\f', '\\/',
                 '\\u00e9', '\\u0000', '\\ud83d\\ude00']
_WIRE_PLAIN = ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
               "0123456789 ._-:/")

_DOC_KEY_POOL = ["id", "ts", "level", "msg", "src", "dur_ms", "user", "ip",
                 "path", "status", "bytes", "trace", "span", "host", "svc",
                 "attempt", "region", "tenant", "shard", "epoch_ms",
                 "request_id", "user_agent", "referrer", "session"]



FIXTURES = {
    "nested.json": (gen_nested_json, [16 * MIB]),
    "wide.json": (gen_wide_json, [8 * MIB]),
    "escape.json": (gen_escape_json, [8 * MIB]),
    "longtext.json": (gen_longtext_json, [8 * MIB]),
    "utf8.json": (gen_utf8_json, [8 * MIB]),
    "logs.json": (gen_logs_json, [8 * MIB]),
    "logs.jsonc": (gen_logs_dialect, [8 * MIB, False]),
    "logs.json5": (gen_logs_dialect, [8 * MIB, True]),
    "pretty.json": (gen_pretty_json, [8 * MIB]),
    "table.csv": (gen_table_csv, [16 * MIB]),
    "wide.csv": (gen_wide_csv, [8 * MIB]),
    "table.tsv": (gen_table_csv, [8 * MIB, "\t"]),
    "deep.json": (gen_deep_json, [8 * MIB]),
    "documents.json": (gen_documents_json, [8 * MIB]),
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 when a fixture's hash is not the manifest's")
    ap.add_argument("names", nargs="*", metavar="NAME", help="write only these fixtures")
    a = ap.parse_args()
    unknown = [n for n in a.names if n not in FIXTURES]
    if unknown:
        ap.error("unknown fixture: " + ", ".join(unknown))
    names = sorted(a.names or FIXTURES)
    with open(os.path.join(HERE, "manifest.toml"), "rb") as f:
        pinned = tomllib.load(f)["fixtures"]
    os.makedirs(OUT, exist_ok=True)
    off = []
    for name in names:
        gen, args = FIXTURES[name]
        data = gen(*args)
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        digest = hashlib.sha256(data).hexdigest()
        if digest != pinned.get(name):
            off.append(name)
        print('"%s" = "%s"' % (name, digest))
    if off:
        print("not the manifest's bytes: " + ", ".join(off), file=sys.stderr)
        return 1 if a.check else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
