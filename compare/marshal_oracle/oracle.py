"""oracle.py OLD_DIR NEW_DIR: the two trees' texts must be the same bytes, but for the accepted difference below.

Accepted: a float's layout. next/ spells floats as jq does (`1e+16`, `1e-05`, fixed up to 1e15) and the old tree as
ECMAScript does (`1e+21`, `1e-7`). A differing stretch counts only when both sides are one number token of equal value.
"""
import os, re, sys

NUMBER = re.compile(rb"-?\d+(\.\d+)?([eE][-+]?\d+)?")


def same(old, new):
    """Whether the texts agree, and the offset of the first real difference otherwise. Returns (offset, accepted)."""
    i = j = accepted = 0
    while i < len(old) and j < len(new):
        if old[i] == new[j]:
            i, j = i + 1, j + 1
            continue
        a, b = i, j
        while a > 0 and old[a - 1] in b"-+.0123456789eE":
            a -= 1
            b -= 1
        x, y = NUMBER.match(old, a), NUMBER.match(new, b)
        if x and y and x.end() > i and y.end() > j and float(x.group()) == float(y.group()):
            i, j = x.end(), y.end()
            accepted += 1
            continue
        return i, accepted
    return (None if i == len(old) and j == len(new) else i), accepted


def main():
    old_dir, new_dir = sys.argv[1:3]
    failed = 0
    for name in sorted(os.listdir(old_dir)):
        old = open(os.path.join(old_dir, name), "rb").read()
        new = open(os.path.join(new_dir, name), "rb").read()
        at, accepted = same(old, new)
        if at is None:
            print(f"{name}: same, {len(new)} bytes, {accepted} float layouts")
        else:
            failed = 1
            print(f"{name}: differs at {at}\n  old {old[max(0, at - 50):at + 50]!r}\n  new {new[max(0, at - 50):at + 50]!r}")
    sys.exit(failed)


if __name__ == "__main__":
    main()
