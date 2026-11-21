"""Fails when an x86-64 object's procedures outside the V3 tier hold instructions an x86-64-v2 CPU lacks: VEX or EVEX, BMI1 and BMI2
but `tzcnt`, LZCNT, PCLMULQDQ and MOVBE.

usage: tier_check.py OBJDUMP OBJECT

A procedure is in the V3 tier by its name's `_v3` suffix; every other one is held to x86-64-v2. The check also fails when no V3 procedure holds one of
these instructions, since then the disassembly is not being read as expected.
"""

import re
import subprocess
import sys

SYMBOL = re.compile(r"^[0-9a-f]+ <(.+)>:$")
V3 = re.compile(r"(?:^|::)\w+_v3(?!\w)")
# AT&T mnemonics past x86-64-v2. `lzcnt` runs as `bsr` on a CPU without it and answers differently. `tzcnt` is not
# here: LLVM emits it as `rep bsf` for a non-zero input on any CPU, where it runs as `bsf` with the same answer.
BEYOND_V2 = re.compile(r"v\w+|(andn|bextr|blsi|blsmsk|blsr|bzhi|lzcnt|movbe|mulx|pdep|pext|rorx|sarx|shlx|shrx)[wlq]?|pclmul\w*")
# A disassembly line: address, colon, then the mnemonic (raw bytes are not shown).
INSTRUCTION = re.compile(r"^\s+[0-9a-f]+:\s+(\S+)")


def main() -> int:
    objdump, obj = sys.argv[1], sys.argv[2]
    text = subprocess.run(
        [objdump, "-d", "--no-show-raw-insn", obj], check=True, capture_output=True, text=True
    ).stdout
    v3, symbol = False, ""
    bad: dict[str, set[str]] = {}
    v3_beyond = 0
    for line in text.splitlines():
        if m := SYMBOL.match(line):
            symbol = m.group(1)
            v3 = V3.search(symbol) is not None
            continue
        if not (m := INSTRUCTION.match(line)) or not BEYOND_V2.fullmatch(m.group(1)):
            continue
        if v3:
            v3_beyond += 1
        else:
            bad.setdefault(symbol, set()).add(m.group(1))
    for symbol, ops in bad.items():
        print(f"{obj}: {symbol} holds {', '.join(sorted(ops))}")
    if v3_beyond == 0:
        print(f"{obj}: no V3 procedure holds an instruction past x86-64-v2")
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
