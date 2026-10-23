#!/usr/bin/env python3
"""Writes the bench fixtures to bench/fixtures/<name> and prints each one's SHA-256.

The output is deterministic (no clock, no network, only seeded PRNGs), so it matches bench/manifest.toml's
[fixtures] hashes. Most generators use CPython's `random` module; the hashes are tested on CPython 3.14, and
another release may change the bytes. With no NAME every fixture is written. After a generator change, paste
the printed hashes into the manifest.

Every fixture is strictly valid JSON (the `.csv` and `.tsv` ones strictly valid CSV in their dialect) unless
its docstring says otherwise. Each generator parses its own output to check this.

    python3 bench/gen.py [NAME...] [--check]
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
# The probe and the other libraries' arms read the fixtures from here.
OUT = os.path.join(HERE, "fixtures")


def gen_config_json(target: int) -> bytes:
    """Returns a large flat object whose two demanded keys are last."""
    rnd = random.Random(20260929)
    parts = []
    i = 0
    while sum(len(p) for p in parts) < target - 256:
        key = "k%07d" % i
        val = rnd.randrange(0, 1 << 31)
        parts.append('"%s":%d,' % (key, val))
        i += 1
    parts.append('"name":"stury",')
    parts.append('"port":8080')
    return ("{" + "".join(parts) + "}").encode()


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


def gen_ndjson(target: int, record_bytes: int = 512) -> bytes:
    rnd = random.Random(7)
    out = bytearray()
    n = 0
    while len(out) < target:
        pad = "x" * max(0, record_bytes - 120)
        rec = {"o": n, "v": rnd.randrange(1 << 32), "p": pad}
        out += json.dumps(rec, separators=(",", ":")).encode() + b"\n"
        n += 1
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


def gen_utf8_sparse_json(target: int) -> bytes:
    """Returns gen_longtext_json's shape with ~2% of bytes non-ASCII (an accented
    name, an emoji). Throughput is non-linear in the non-ASCII share, so this
    density has its own fixture. Characters are ~90% 2-byte, 10% 4-byte."""
    rnd = random.Random(20241002)
    twobyte = "áéíóúàèìòùâêîôûäëïöüñçαβγδεζηθικλμνξοπρστυφχψ"
    fourbyte = "😀🎉🚀🔥✨🌈🍕🎸🐙🌍"
    out = bytearray(b'[')
    first = True
    while len(out) < target:
        paras = []
        for _ in range(rnd.randrange(2, 5)):
            words = []
            # one non-ASCII character per ~100 bytes of ASCII text
            for _ in range(rnd.randrange(200, 500)):
                w = ''.join(rnd.choice("abcdefghijklmnopqrstuvwxyz")
                            for _ in range(rnd.randrange(3, 9)))
                if rnd.randrange(18) == 0:
                    w = w[:1] + (rnd.choice(fourbyte) if rnd.randrange(10) == 0
                                 else rnd.choice(twobyte)) + w[1:]
                words.append(w)
            paras.append(' '.join(words))
        rec = {"id": rnd.randrange(1 << 40), "body": "\n\n".join(paras),
               "tags": ["t%d" % rnd.randrange(100) for _ in range(4)]}
        if not first:
            out += b','
        out += json.dumps(rec, separators=(",", ":"),
                          ensure_ascii=False).encode('utf-8')
        first = False
    out += b']'
    data = bytes(out)
    json.loads(data.decode('utf-8'))
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


def gen_bignum_json(target: int) -> bytes:
    """Returns an array of numbers whose digits or exponent reach the caps rather
    than binary64's width. Widths straddle 19/20 digits (the u64 edge) and 38/39
    (the u128 edge) and reach 255 (the widest under the digit cap). Exponents
    straddle 308/309 (binary64's range) and 4095/4096 (the scale cap)."""
    rnd = random.Random(20261003)
    widths = [19, 20, 38, 39, 39, 39, 128, 255]
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        w = rnd.choice(widths)
        digs = str(rnd.randrange(1, 10)) + "".join(
            str(rnd.randrange(10)) for _ in range(w - 1))
        shape = rnd.randrange(4)
        if shape == 0:
            tok = digs                                        # pure integer
        elif shape == 1:
            tok = "-" + digs
        elif shape == 2:
            tok = "0." + digs                                 # leading frac
        else:
            e = rnd.choice([308, 309, 4095, 4096])            # binary64 vs the cap
            tok = digs + "e-" + str(e)
        if not first:
            out += b","
        out += tok.encode()
        first = False
    out += b"]"
    data = bytes(out)
    json.loads(data)
    return data


def gen_dups_json() -> bytes:
    """Returns one flat object with repeated top-level keys, on which a last-wins
    read and a skip read give the same answer for different work.

    The members are written by hand because a Python dict collapses repeated
    keys. The object is flat because a named-member read covers only the
    top-level object's members.

    4096 distinct keys repeat 6 times each, so a last-wins read compares 6
    candidates per key and a skip read steps over 24576 members."""
    rnd = random.Random(20261004)
    n_keys = 4096
    repeats = 6
    members = []
    for k in range(n_keys):
        for _ in range(repeats - 1):        # earlier occurrences, all shadowed
            members.append('"k%04d":%d' % (k, rnd.randrange(1 << 31)))
        members.append('"k%04d":%d' % (k, rnd.randrange(1 << 31)))   # the winner
    out = bytearray(b"{")
    out += (",".join(members)).encode()
    out += b"}"
    data = bytes(out)
    json.loads(data)
    # json.loads collapses repeats, so count them in the bytes.
    assert data.count(b'"k0000":') == repeats, "duplicates did not survive"
    assert data.count(b'"k0001":') == repeats
    return data


def gen_splice_json(target: int) -> bytes:
    rnd = random.Random(31337)
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        rec = {"i": rnd.randrange(1 << 32), "s": "v" * 32, "flag": bool(rnd.getrandbits(1))}
        if not first:
            out += b","
        out += json.dumps(rec, separators=(",", ":")).encode()
        first = False
    out += b"]"
    return bytes(out)


def gen_deep_json(target: int) -> bytes:
    """Returns an array of 256-deep array chains. The other fixtures nest at most
    8 deep; depthwide_* varies depth in a grid. 256 is under the 1024 depth cap
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


def gen_findesc_json(target: int) -> bytes:
    """Returns a flat object whose keys are escape-spelled, so a named-member read
    decodes each key to compare it. Every key is `k%06d` decoded but `\\u006b%06d`
    on the wire, so a raw-bytes compare never matches. `wide.json` has the same
    shape with plain keys. The first keys are asserted present so the lanes'
    lookups hit."""
    rnd = random.Random(20261011)
    out = bytearray(b"{")
    first = True
    i = 0
    while len(out) < target:
        if not first:
            out += b","
        out += ('"\\u006b%06d":%d' % (i, rnd.randrange(1 << 31))).encode()
        first = False
        i += 1
    out += b"}"
    data = bytes(out)
    json.loads(data)
    assert data.count(b"\\u006b000000") == 1, "escaped keys did not survive"
    assert data.count(b"\\u006b000007") == 1
    return data


def gen_fault_json(target: int) -> bytes:
    """Returns valid nested records with one invalid wire byte 10 bytes from the
    end, for the error path (kind and exact offset). It is the only fixture that
    is not strictly valid. A reader validates almost the whole document before
    refusing it. The generator asserts that it fails to parse."""
    rnd = random.Random(20261012)
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        rec = {
            "id": rnd.randrange(1 << 40),
            "name": "".join(rnd.choice("abcdefghij") for _ in range(24)),
            "tags": [rnd.randrange(1000) for _ in range(6)],
            "ok": bool(rnd.getrandbits(1)),
        }
        if not first:
            out += b","
        out += json.dumps(rec, separators=(",", ":")).encode()
        first = False
    out += b"]"
    data = bytearray(bytes(out))
    data[len(data) - 10] = 0xFF  # invalid wire byte, 10 from the end
    data = bytes(data)
    try:
        json.loads(data.decode("utf-8"))
    except Exception:
        return data
    raise AssertionError("fault fixture parsed as valid; corruption did not take")


def gen_tiny_json(target: int) -> bytes:
    """Returns a ~2 KB array of records; every other fixture is hundreds of KB or
    more. Per-call setup dominates at this size, so its lane reports ns, not GB/s."""
    rnd = random.Random(20261013)
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        rec = {
            "id": rnd.randrange(1 << 40),
            "name": "".join(rnd.choice("abcdefghij") for _ in range(24)),
            "tags": [rnd.randrange(1000) for _ in range(6)],
            "ok": bool(rnd.getrandbits(1)),
        }
        if not first:
            out += b","
        out += json.dumps(rec, separators=(",", ":")).encode()
        first = False
    out += b"]"
    data = bytes(out)
    json.loads(data)
    return data


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


# CSV and TSV fixtures. Every row has the header's width, no cell is empty (a typed read treats an empty cell
# as absent), and numbers have a fixed number of decimals so every reader parses the same value.
_CSV_FIRST = ["Ada", "Boris", "Chen", "Dalia", "Emre", "Farah", "Goran", "Hana", "Ivo", "Jun", "Zoë",
              "Łukasz", "Søren", "Amélie", "Renée"]
_CSV_LAST = ["Nowak", "Okafor", "Lindqvist", "Tanaka", "Müller", "Haddad", "Silva", "Kowalski", "Dubois",
             "O'Neil", "Petrov", "Ngu"]
_CSV_CITIES = ["Oslo", "Lagos", "Kraków", "Osaka", "Lima", "Washington, DC", "St. John's", "Zürich", "Hanoi",
               "Perth", "Quito", "Reykjavík"]
_CSV_WORDS = ["the", "quick", "ledger", "closes", "on", "friday", "after", "audit", "review", "of", "returns",
              "and", "refunds", "pending", "carrier", "dispute", "escalated", "to", "billing", "team"]


def _csv_cell(s: str, delimiter: str = ",") -> str:
    """Quotes S, per RFC 4180's minimal quoting, only when it contains the delimiter, a quote, CR or LF."""
    if delimiter in s or any(c in s for c in '"\r\n'):
        return '"' + s.replace('"', '""') + '"'
    return s


def _check_csv(data: bytes, delimiter: str, quoting: int, columns: int) -> bytes:
    """Returns DATA when it parses strictly into rows all COLUMNS wide; asserts otherwise."""
    rows = list(csv.reader(io.StringIO(data.decode("utf-8"), newline=""), delimiter=delimiter,
                           quoting=quoting, strict=True))
    assert rows and all(len(r) == columns for r in rows), "ragged or empty csv fixture"
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


def gen_text_csv(target: int) -> bytes:
    """Returns a text table with quoting: UTF-8 names, cities containing a comma, and a free-text column quoted when
    it contains a comma (1 row in 3), a doubled quote (1 in 4) or an LF (1 in 12)."""
    rng = _Lcg(0xC5F0002)
    out = ["id,name,city,quote,note\n"]
    size, i = len(out[0]), 0
    while size < target:
        words = [rng.pick(_CSV_WORDS) for _ in range(4 + rng.below(10))]
        if rng.below(3) == 0:
            words[1] += ","
        if rng.below(4) == 0:
            words[2] = '"%s"' % words[2]
        if rng.below(12) == 0:
            words[3] += "\n"
        row = ",".join([
            str(i), _csv_cell(rng.pick(_CSV_FIRST) + " " + rng.pick(_CSV_LAST)), _csv_cell(rng.pick(_CSV_CITIES)),
            _csv_cell(" ".join(words)), _csv_cell("n%d%s" % (rng.below(100000), ", ok" if rng.below(6) == 0 else ""))
        ]) + "\n"
        out.append(row)
        size += len(row.encode())
        i += 1
    return _check_csv("".join(out).encode("utf-8"), ",", csv.QUOTE_MINIMAL, 5)


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


def gen_batch_json(n: int) -> bytes:
    """Returns N small flat records `[{"i","s","f","n"}, ...]`, each `s` a 40-character base64url string, for
    the jq comparison's `.[].s` case."""
    rnd = _Lcg(n)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    rows = []
    for i in range(n):
        s = "".join(alphabet[rnd.below(64)] for _ in range(40))
        f = "true" if rnd.below(2) else "false"
        rows.append('{"i":%d,"s":"%s","f":%s,"n":%d}' % (i, s, f, rnd.below(1 << 31)))
    return ("[" + ",".join(rows) + "]").encode()


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


# Token builders shared by documents.json, decode.json and the NDJSON pair.
_WIRE_ESCAPES = ['\\"', '\\\\', '\\n', '\\r', '\\t', '\\b', '\\f', '\\/',
                 '\\u00e9', '\\u0000', '\\ud83d\\ude00']
_WIRE_PLAIN = ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
               "0123456789 ._-:/")

_DOC_KEY_POOL = ["id", "ts", "level", "msg", "src", "dur_ms", "user", "ip",
                 "path", "status", "bytes", "trace", "span", "host", "svc",
                 "attempt", "region", "tenant", "shard", "epoch_ms",
                 "request_id", "user_agent", "referrer", "session"]


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


def gen_decode_json(target: int) -> bytes:
    """Returns keyed documents with wide mantissas, where number decoding is the
    work. Unlike bignum.json's bare tokens, the numbers sit among keys, arrays,
    strings and literals. Widths 16..38 straddle the u64 edge (19/20) and reach
    the u128 edge (38) without crossing it. Half the fractionals are `0.x`."""
    rnd = random.Random(20261023)
    keys = ["px", "py", "pz", "acc", "vel", "mass", "rate", "lambda_k",
            "integral", "energy", "momentum", "delta", "sigma", "mu", "eps",
            "omega", "theta", "grad", "hess", "trace2"]

    def scalar():
        r = rnd.random()
        if r < 0.78:
            return _num_token(rnd, 16, 38, frac_p=0.42, exp_p=0.22, skew=1.35)
        if r < 0.90:
            return _wire_string(rnd, rnd.choice([0, 3, 7, 8, 12, 19, 23, 31]),
                                0.10)
        if r < 0.96:
            return rnd.choice(["true", "false", "null"])
        return _num_token(rnd, 1, 6, frac_p=0.5, exp_p=0.1)

    def container(depth):
        n = rnd.randrange(1, 9)
        if rnd.random() < 0.35:
            return "[" + ",".join(scalar() for _ in range(n)) + "]"
        return "{" + ",".join('"%s":%s' % (k, scalar())
                              for k in rnd.sample(keys, n)) + "}"

    def value(depth):
        if depth < 3 and rnd.random() < 0.20:
            return container(depth)
        return scalar()

    out = bytearray(b"[")
    first = True
    while len(out) < target:
        if not first:
            out += b","
        out += value(0).encode()
        first = False
    out += b"]"
    data = bytes(out)
    json.loads(data)
    return data


def _padded_object(members, size):
    """Returns `{"m1":v1,...,"p":"xxx"}` of exactly SIZE bytes; the length of the
    pad member `p` sets the size."""
    def build(pad):
        body = ",".join(members + ['"p":"%s"' % ("x" * pad)])
        return "{" + body + "}"

    pad = size - len(build(0))
    if pad < 0:
        raise ValueError("members exceed %d B by %d" % (size, -pad))
    obj = build(pad)
    assert len(obj) == size, (len(obj), size)
    return obj


def _fixed_cost_records(docs, rec_bytes, seed, short_last=0):
    """Returns the DOCS records that both files of the byte-matched NDJSON pair
    are built from. Both use this generator and seed, so the files differ only in
    how many documents the bytes form. 4-7 members, one nested container, no
    escapes."""
    rnd = random.Random(seed)
    out = []
    for i in range(docs):
        want = rec_bytes - (short_last if i == docs - 1 else 0)
        members = []
        budget = want - 2 - 12
        while True:
            k = _DOC_KEY_POOL[rnd.randrange(len(_DOC_KEY_POOL))]
            r = rnd.random()
            if r < 0.30:
                v = str(rnd.randrange(1, 10 ** rnd.randrange(1, 10)))
            elif r < 0.55:
                v = _wire_string(rnd, rnd.randrange(3, 16), 0.0)
            elif r < 0.72:
                v = "[%d,%d]" % (rnd.randrange(1000), rnd.randrange(1000))
            elif r < 0.88:
                v = '{"%s":%d}' % (
                    _DOC_KEY_POOL[rnd.randrange(len(_DOC_KEY_POOL))],
                    rnd.randrange(1 << 20))
            else:
                v = rnd.choice(["true", "false"])
            m = '"%s":%s' % (k, v)
            if sum(len(x) + 1 for x in members) + len(m) + 1 > budget:
                break
            members.append(m)
        out.append(_padded_object(members, want))
    return out


def gen_manysmall_ndjson(docs: int, rec_bytes: int) -> bytes:
    """Returns DOCS records of exactly REC_BYTES bytes, one per line. The file is
    exactly `docs * (rec_bytes + 1)` bytes."""
    recs = _fixed_cost_records(docs, rec_bytes, 20261025)
    data = "".join(r + "\n" for r in recs).encode()
    assert len(data) == docs * (rec_bytes + 1), len(data)
    for r in recs:
        json.loads(r)
    return data


def gen_onebig_ndjson(docs: int, rec_bytes: int) -> bytes:
    """Returns the same records as one array, the same size as
    `gen_manysmall_ndjson`'s file. The last record is 2 B shorter to make room for
    `[`, `]` and the commas, so the pair differs only in per-document start cost."""
    recs = _fixed_cost_records(docs, rec_bytes, 20261025, short_last=2)
    data = ("[" + ",".join(recs) + "]\n").encode()
    assert len(data) == docs * (rec_bytes + 1), len(data)
    json.loads(data)
    return data


# The three ws_* documents hold the same values (asserted equal after whitespace
# removal); only the whitespace density differs.
_WS_MODES = ("ws_none", "ws_60", "ws_85")
_WS_RATIO = {"ws_none": 0.0, "ws_60": 0.62, "ws_85": 0.86}
_WS_CHARS = (b" ", b"\n", b"\t", b"\r", b"  ", b"\n\n")


def gen_ws_heavy_json(n_records):
    """Returns three documents of N_RECORDS records, one per whitespace mode,
    with whitespace runs of tens to hundreds of bytes between tokens."""
    outs = {}
    for mode in _WS_MODES:
        rnd = random.Random(20261103)
        parts = []
        for i in range(n_records):
            rec = json.dumps({
                "id": rnd.randrange(1 << 40),
                "name": "n%08d" % rnd.randrange(100000000),
                "v": rnd.randrange(1 << 31),
                "flag": bool(rnd.getrandbits(1)),
            }, separators=(",", ":")).encode()
            parts.append(rec)
        joined = b",".join(parts)
        nonws = len(joined) + 2                    # `[` + `]`
        # One run per legal gap (after `[`, either side of each comma, before `]`): n_records + 1.
        tokens = n_records + 1
        if mode == "ws_none":
            outs[mode] = b"[" + joined + b"]"
            continue
        ratio = _WS_RATIO[mode]
        # Rounded up so the whitespace share is at or above the target.
        per = int(-(-(ratio / (1.0 - ratio) * nonws) // tokens))
        per = max(per, 1)
        ws = [_WS_CHARS[k % len(_WS_CHARS)] * per for k in range(tokens)]
        body = bytearray()
        body += b"["
        body += ws[0]
        for k, rec in enumerate(parts):
            body += rec
            if k + 1 < len(parts):
                body += ws[1 + k]
                body += b","
        body += ws[-1]
        body += b"]"
        outs[mode] = bytes(body)
    strip = lambda b: b.translate(None, b" \t\n\r")
    assert strip(outs["ws_none"]) == strip(outs["ws_60"]) == strip(outs["ws_85"]), \
        "the ws modes must hold ONE value mix; whitespace is the only difference"
    return outs


# Every depth x width fixture has the same size and 8-digit elements, so depth
# does not change value density as it does in deep.json.
def gen_depthwide_json(target, depth, width):
    """Returns an array of WIDTH-wide array chains of 8-digit numbers. DEPTH is
    the document's maximum nesting, top-level array included."""
    assert depth >= 2, "depth 1 has no chain; the top-level array is depth 1"
    rnd = random.Random(20261104)
    inner = depth - 1
    chain = b"[" * inner
    # Starts at 10**7 because a leading zero would make the number invalid.
    chain += b",".join(b"%08d" % rnd.randrange(10000000, 100000000)
                       for _ in range(width))
    chain += b"]" * inner
    assert chain[:inner] == b"[" * inner and chain[-inner:] == b"]" * inner
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        if not first:
            out += b","
        out += chain
        first = False
    out += b"]"
    data = bytes(out)
    if depth <= 1024:
        json.loads(data)
    return data


# In a numstr pair the number arm writes an L-byte token where the string arm
# writes `"` + digits[:L-2] + `"`, so the two files have the same length and
# differ only in value class.
_NUMSTR_CLASSES = ("num_short", "str_short", "num_wide", "str_wide",
                   "num_45", "bool")


def gen_numstr_json(target, klass):
    """Returns one numstr arm: values of class KLASS only, in the same structure as its pair."""
    assert klass in _NUMSTR_CLASSES, "unknown numstr class %r" % (klass,)
    wide = klass.endswith("wide")
    as_string = klass.startswith("str")
    rnd = random.Random(20261105)
    keys = ["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8", "k9", "k10",
        "k11"]
    lengths = [16, 17, 18, 19, 20, 22, 24, 28, 31, 34, 38] if wide \
        else ([4, 5] if klass in ("num_45", "bool") else [4, 5, 6, 7])
    out = bytearray(b"[")
    first = True
    while len(out) < target:
        # A per-record member count keeps the class stream aperiodic.
        n = 4 + rnd.randrange(9)
        members = []
        for j in range(n):
            k = keys[j % len(keys)]
            L = lengths[(j + rnd.randrange(len(lengths))) % len(lengths)]
            digs = str(rnd.randrange(1, 10)) + "".join(
                str(rnd.randrange(10)) for _ in range(L - 1))
            # Every arm draws the same values in the same order, so pairs stay
            # byte-matched. That is why the `0.x` coin is drawn before the class branch.
            cluster = wide and rnd.random() < 0.5
            if as_string:
                tok = '"' + digs[:L - 2] + '"'
            elif klass == "bool":
                # `true`/`null` are 4 B and `false` is 5 B, so a byte-matched
                # literal exists only at L in {4,5}. The boolean arm pairs with `num_45`.
                tok = "true" if L == 4 else "false"
            elif cluster:
                # Half the wide tokens are `0.x`: a leading zero takes its own
                # decoder branch, and `gen_decode_json` mixes them in at only 42%.
                # `0.` is 2 B and the body L-2 B, so the token is still L bytes.
                tok = "0." + digs[:L - 2]
            else:
                tok = digs
            members.append('"%s":%s' % (k, tok))
        if not first:
            out += b","
        out += ("{" + ",".join(members) + "}").encode()
        first = False
    out += b"]"
    data = bytes(out)
    json.loads(data)
    return data


def gen_ws_json(n_records, mode):
    return gen_ws_heavy_json(n_records)[mode]


FIXTURES = {
    "nested.json": (gen_nested_json, [16 * MIB]),
    "wide.json": (gen_wide_json, [8 * MIB]),
    "escape.json": (gen_escape_json, [8 * MIB]),
    "longtext.json": (gen_longtext_json, [8 * MIB]),
    "utf8.json": (gen_utf8_json, [8 * MIB]),
    "utf8_sparse.json": (gen_utf8_sparse_json, [8 * MIB]),
    "logs.json": (gen_logs_json, [8 * MIB]),
    "batch_131072.json": (gen_batch_json, [131072]),
    "pretty.json": (gen_pretty_json, [8 * MIB]),
    "records.ndjson": (gen_ndjson, [5800000]),
    "table.csv": (gen_table_csv, [16 * MIB]),
    "text.csv": (gen_text_csv, [16 * MIB]),
    "wide.csv": (gen_wide_csv, [8 * MIB]),
    "table.tsv": (gen_table_csv, [8 * MIB, "\t"]),
    # Past the CLI's STREAM_FILE_MIN (64 MiB), so `stury -c .v` reads it as a stream.
    "stream.ndjson": (gen_ndjson, [72 * MIB]),
    "dups.json": (gen_dups_json, []),
    "splice.json": (gen_splice_json, [10 * MIB]),
    "edit.json": (gen_splice_json, [16 * MIB]),
    "config.json": (gen_config_json, [1 * MIB]),
    "deep.json": (gen_deep_json, [8 * MIB]),
    "findesc.json": (gen_findesc_json, [1 * MIB]),
    "fault.json": (gen_fault_json, [1 * MIB]),
    "tiny.json": (gen_tiny_json, [2048]),
    "documents.json": (gen_documents_json, [8 * MIB]),
    "decode.json": (gen_decode_json, [8 * MIB]),
    "bignum.json": (gen_bignum_json, [8 * MIB]),
    "manysmall.ndjson": (gen_manysmall_ndjson, [32768, 128]),
    "onebig.ndjson": (gen_onebig_ndjson, [32768, 128]),
    **{"%s.json" % m: (gen_ws_json, [40000, m]) for m in _WS_MODES},
    **{"depthwide_d%d_w%d.json" % (d, w): (gen_depthwide_json, [8 * MIB, d, w])
       for d in (2, 16, 256, 1023) for w in (1, 64)},
    "depthwide_d1024_w1.json": (gen_depthwide_json, [1 * MIB, 1024, 1]),
    **{"numstr_%s.json" % k: (gen_numstr_json, [16 * MIB, k]) for k in _NUMSTR_CLASSES},
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
    # The `json.loads` self-check recurses once per nesting level; the depth-1023 fixtures exceed the default
    # limit of CPython 3.11 and 3.12.
    sys.setrecursionlimit(max(sys.getrecursionlimit(), 4000))
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
