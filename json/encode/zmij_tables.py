#!/usr/bin/env python3
"""Write zmij_tables.odin: zmij's binary64 tables (the `zmij` crate 1.0.23, MIT).

POW10_SIG[i] is the 128-bit significand of 10^(i - 293), rounded down and normalized so bit 127 is set,
computed exactly with Python integers. The crate rebuilds the same table from three small ones (Dougall
Johnson's method); `crate_pow10` repeats that rebuild, and every entry must agree with the exact one.
EXP_SHIFT[raw_exp] is the crate's ExpShiftTable. EXP_STRING[e - EXP_STRING_MIN] is `e±x` for the decimal
exponent e, low byte first, with its length in bits 48..64: the crate's ExpStringTable.

Run from the repository root: python3 json/encode/zmij_tables.py
"""
import pathlib

MASK = (1 << 64) - 1
NUM_POW10 = 618
POW10_MIN = -293
EXTRA_SHIFT = 6
EXP_OFFSET = 1023 + 52
# The crate's MIN_DEC_EXP (f64::MIN_10_EXP - MAX_DIGITS10) through f64::MAX_10_EXP.
EXP_STRING_MIN = -307 - 17
EXP_STRING_MAX = 308


def exact_pow10(k):
    if k >= 0:
        v = 10 ** k
        n = v.bit_length()
        return v << (128 - n) if n <= 128 else v >> (n - 128)
    d = 10 ** -k
    # The smallest s with 2^s / d >= 2^127, then floor(2^s / d) has exactly 128 bits.
    s = 127 + d.bit_length()
    q = (1 << s) // d
    if q.bit_length() > 128:
        q = (1 << (s - 1)) // d
    assert q.bit_length() == 128
    return q


# The crate's three seed tables, copied from src/lib.rs.
POW10_MINOR = [
    0x8000000000000000, 0xa000000000000000, 0xc800000000000000,
    0xfa00000000000000, 0x9c40000000000000, 0xc350000000000000,
    0xf424000000000000, 0x9896800000000000, 0xbebc200000000000,
    0xee6b280000000000, 0x9502f90000000000, 0xba43b74000000000,
    0xe8d4a51000000000, 0x9184e72a00000000, 0xb5e620f480000000,
    0xe35fa931a0000000, 0x8e1bc9bf04000000, 0xb1a2bc2ec5000000,
    0xde0b6b3a76400000, 0x8ac7230489e80000, 0xad78ebc5ac620000,
    0xd8d726b7177a8000, 0x878678326eac9000, 0xa968163f0a57b400,
    0xd3c21bcecceda100, 0x84595161401484a0, 0xa56fa5b99019a5c8,
    0xcecb8f27f4200f3a,
]
POW10_MAJOR = [
    (0xaf8e5410288e1b6f, 0x07ecf0ae5ee44dda), (0xb1442798f49ffb4a, 0x99cd11cfdf41779d),
    (0xb2fe3f0b8599ef07, 0x861fa7e6dcb4aa15), (0xb4bca50b065abe63, 0x0fed077a756b53aa),
    (0xb67f6455292cbf08, 0x1a3bc84c17b1d543), (0xb84687c269ef3bfb, 0x3d5d514f40eea742),
    (0xba121a4650e4ddeb, 0x92f34d62616ce413), (0xbbe226efb628afea, 0x890489f70a55368c),
    (0xbdb6b8e905cb600f, 0x5400e987bbc1c921), (0xbf8fdb78849a5f96, 0xde98520472bdd034),
    (0xc16d9a0095928a27, 0x75b7053c0f178294), (0xc350000000000000, 0x0000000000000000),
    (0xc5371912364ce305, 0x6c28000000000000), (0xc722f0ef9d80aad6, 0x424d3ad2b7b97ef6),
    (0xc913936dd571c84c, 0x03bc3a19cd1e38ea), (0xcb090c8001ab551c, 0x5cadf5bfd3072cc6),
    (0xcd036837130890a1, 0x36dba887c37a8c10), (0xcf02b2c21207ef2e, 0x94f967e45e03f4bc),
    (0xd106f86e69d785c7, 0xe13336d701beba52), (0xd31045a8341ca07c, 0x1ede48111209a051),
    (0xd51ea6fa85785631, 0x552a74227f3ea566), (0xd732290fbacaf133, 0xa97c177947ad4096),
    (0xd94ad8b1c7380874, 0x18375281ae7822bc),
]
POW10_FIXUPS = [
    0x0a4e363f, 0x00001840, 0x00006400, 0x24200040, 0x00000000,
    0x0c000000, 0x82c81380, 0x5e4ce01f, 0xd730f60f, 0x0000001b,
    0x00000000, 0xcdf7fffc, 0x6e8201d8, 0x40cd3fd1, 0xdb642501,
    0x00000d0d, 0x14042400, 0x53713840, 0x11781db4, 0x00000000,
]


def crate_pow10(i):
    m = POW10_MINOR[(i + 10) % 28]
    h_hi, h_lo = POW10_MAJOR[(i + 10) // 28]
    h1 = (h_lo * m) >> 64
    c0 = (h_lo * m) & MASK
    c1 = (h1 + h_hi * m) & MASK
    c2 = int(c1 < h1) + ((h_hi * m) >> 64)
    if c2 >> 63:
        hi, lo = c2, c1
    else:
        hi, lo = ((c2 << 1) | (c1 >> 63)) & MASK, ((c1 << 1) | (c0 >> 63)) & MASK
    lo -= (POW10_FIXUPS[i >> 5] >> (i & 31)) & 1
    return (hi << 64) | lo


def compute_dec_exp(bin_exp, regular):
    return (bin_exp * 315653 - (0 if regular else 131072)) >> 20


def compute_exp_shift(bin_exp, dec_exp):
    return (bin_exp + ((-dec_exp * 217707) >> 16) + 1) & 0xFF


def exp_shift(raw_exp):
    bin_exp = raw_exp - EXP_OFFSET + (1 if raw_exp == 0 else 0)
    return (compute_exp_shift(bin_exp, compute_dec_exp(bin_exp, True) + 1) + EXTRA_SHIFT) & 0xFF


pow10 = [exact_pow10(POW10_MIN + i) for i in range(NUM_POW10)]
for i, v in enumerate(pow10):
    assert crate_pow10(i) == v, i
assert pow10[5 - POW10_MIN] == 0xc350000000000000 << 64
assert pow10[-303 - POW10_MIN + 10] == crate_pow10(-303 - POW10_MIN + 10)
assert pow10[0 - POW10_MIN] == 1 << 127
shifts = [exp_shift(r) for r in range(2048)]
assert shifts[0] == shifts[1]
assert all(EXTRA_SHIFT - 3 <= s <= EXTRA_SHIFT + 5 for s in shifts), sorted(set(shifts))



def exp_string(e):
    text = ("e%s%d" % ("-" if e < 0 else "+", abs(e))).encode()
    return len(text) << 48 | int.from_bytes(text, "little")


exp_strings = [exp_string(e) for e in range(EXP_STRING_MIN, EXP_STRING_MAX + 1)]
assert exp_strings[-EXP_STRING_MIN] == 3 << 48 | int.from_bytes(b"e+0", "little")


def rows(name, typ, items):
    return "\n".join(["@(rodata)", "%s: %s = {" % (name, typ)] + items + ["}"])


out = "\n".join([
    "package encode",
    "",
    "// Generated by zmij_tables.py; do not edit. POW10_SIG[i] = {hi, lo} of the 128-bit significand of",
    "// 10^(i + POW10_MIN), rounded down. EXP_SHIFT[raw_exp] is the shift that puts the integral part of a",
    "// scaled binary64 significand with that biased exponent above the low EXTRA_SHIFT bits of the top word.",
    "// EXP_STRING[e - EXP_STRING_MIN] is `e±x` for the decimal exponent e, low byte first, its length in",
    "// bits 48..64.",
    "",
    "POW10_MIN :: %d" % POW10_MIN,
    "EXP_STRING_MIN :: %d" % EXP_STRING_MIN,
    "",
    rows("POW10_SIG", "[%d][2]u64" % NUM_POW10,
         ["\t" + " ".join("{0x%016x, 0x%016x}," % (v >> 64, v & MASK) for v in pow10[i:i + 2])
          for i in range(0, NUM_POW10, 2)]),
    "",
    rows("EXP_SHIFT", "[2048]u8",
         ["\t" + ", ".join(str(s) for s in shifts[i:i + 32]) + "," for i in range(0, 2048, 32)]),
    "",
    rows("EXP_STRING", "[%d]u64" % len(exp_strings),
         ["\t" + ", ".join("0x%016x" % v for v in exp_strings[i:i + 4]) + "," for i in range(0, len(exp_strings), 4)]),
    "",
])
pathlib.Path(__file__).with_name("zmij_tables.odin").write_text(out)
