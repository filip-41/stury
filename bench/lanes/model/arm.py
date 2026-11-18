"""The driver of the Python arms of the model lane: `ARM.py SHAPE FILE MODE`, SHAPE `logs` or `twitter`, FILE one JSON
record per line, MODE `load`, `first` or `dump`. An arm's module builds a `Shape` for each shape and runs `main` over
them. Each call of a mode does every record of FILE, and the check is the one the Odin probe prints: the number of
accepted records, the sum of the shape's tally member over them, and for `load` how many records refused each member path,
in path order. `dump` hashes the text of every record, and GB/s counts that text's bytes."""

import gc
import os
import re
import sys
from typing import Callable, NamedTuple

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "timing"))
import timing  # noqa: E402


class Shape(NamedTuple):
    tally: str
    """The member whose values the check sums."""
    load: Callable | None
    """lines -> (models, failed): the accepted records' models, and for each refused record every member path it
    refused. None for a library that stops at a record's first failure."""
    first: Callable | None
    """lines -> (models, refused count), each refused record stopped at its first failure. None for a library that
    cannot stop there."""
    dump: Callable
    """models -> a list of each record's text."""
    spelled: Callable = lambda text: text
    """text -> the text as the check hashes it. Libraries spell a float that has no fraction their own way, `396.0` or `396`,
    and the check holds `duration_ms` to the second."""


DURATION_WITHOUT_FRACTION = re.compile(rb'("duration_ms":[0-9]+)\.0\b')


def logs_spelled(text):
    return DURATION_WITHOUT_FRACTION.sub(rb"\1", text)


def fold(models, failed, tally):
    refused = {}
    for paths in failed:
        for path in set(paths):
            refused[path] = refused.get(path, 0) + 1
    h = timing.fnv_u64(timing.CHECK_OFFSET, len(models))
    h = timing.fnv_u64(h, sum(getattr(m, tally) for m in models))
    for path in sorted(refused):
        h = timing.fnv_bytes(h, path.encode())
        h = timing.fnv_u64(h, refused[path])
    return h


def main(shapes):
    if len(sys.argv) != 4 or sys.argv[1] not in shapes or sys.argv[3] not in ("load", "first", "dump"):
        sys.exit(f"usage: {sys.argv[0]} {'|'.join(shapes)} FILE load|first|dump")
    shape, mode = shapes[sys.argv[1]], sys.argv[3]
    with open(sys.argv[2], "rb") as f:
        src = f.read()
    lines = [line for line in src.split(b"\n") if line]
    gc.disable()
    if mode == "dump":
        models, refused = (shape.load or shape.first)(lines)
        if refused:
            sys.exit("dump needs a file every record of which loads")
        ns, texts = timing.time_runs(lambda: shape.dump(models))
        check, written = timing.CHECK_OFFSET, 0
        for text in texts:
            data = text if isinstance(text, bytes) else text.encode()
            check = timing.fnv_bytes(check, shape.spelled(data))
            written += len(data)
        timing.report(written, ns, check)
    elif mode == "first":
        if shape.first is None:
            sys.exit("this library cannot stop at a record's first failure")
        ns, (models, _) = timing.time_runs(lambda: shape.first(lines))
        timing.report(len(src), ns, fold(models, [], shape.tally))
    else:
        if shape.load is None:
            sys.exit("this library lists no more than a record's first failure")
        ns, (models, failed) = timing.time_runs(lambda: shape.load(lines))
        timing.report(len(src), ns, fold(models, failed, shape.tally))
