"""What every Python probe shares: the sampling rule and the check hash. A job makes WARMUP untimed calls and TIMED
timed ones and prints the median as key=value tokens. The Odin, C, C++ and Rust probes follow the same rule and hash
(timing.odin, timing.h, timing.rs)."""

import time

WARMUP = 2
TIMED = 10

CHECK_OFFSET = 14695981039346656037
CHECK_PRIME = 1099511628211
MASK = (1 << 64) - 1


def fnv_bytes(h, data):
    for b in data:
        h = ((h ^ b) * CHECK_PRIME) & MASK
    return h


def fnv_u64(h, v):
    return fnv_bytes(h, (v & MASK).to_bytes(8, "little"))


def time_runs(f):
    """The median ns of TIMED calls of F after WARMUP untimed ones, and the last call's value. An earlier value is dropped
    before the next call starts, so only one call's value is live at a time."""
    times = []
    kept = None
    for i in range(WARMUP + TIMED):
        kept = None
        t0 = time.perf_counter_ns()
        v = f()
        ns = time.perf_counter_ns() - t0
        kept = v
        if i >= WARMUP:
            times.append(ns)
    times.sort()
    return (times[(TIMED - 1) // 2] + times[TIMED // 2]) // 2, kept


def report(length, ns, check):
    print(f"gb_per_s={length / ns:.4f} ns={ns} check={check}")
