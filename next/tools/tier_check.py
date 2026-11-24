"""Fails when an x86-64 object holds an instruction past x86-64-v2 where only a V2 CPU's code may run: VEX or EVEX, BMI1 and
BMI2 but `tzcnt`, LZCNT, PCLMULQDQ and MOVBE.

usage: tier_check.py OBJDUMP OBJECT [--inlined] [--require NAME]

The V3 tier is the procedures `lib/base/kernel/tier_amd64.odin`, `dsv/tier_amd64.odin`, `json/strings.odin` and `xml/text.odin` declare for
it, `TIER_ROOTS`, and the procedures only those call, which at -o:none include the kernels `scan_v3` does not inline.
Every other procedure is held to x86-64-v2, so a callee that a V2 path also reaches fails even though a V3 procedure calls it too. The disassembly must hold a
`scan_v3`, or the procedure `--require` names, and some root that reaches an instruction past x86-64-v2, so one not
read as expected fails instead of passing empty. With `--inlined`, for an optimized build, every root must reach one.
"""

import re
import subprocess
import sys

SYMBOL = re.compile(r"^[0-9a-f]+ <(.+)>:$")
# The procedures built with the V3 tier's features: the kernel's, one `scan_v3` per scan op, `set_v3`, the delimited
# passes of `dsv/tier_amd64.odin`, one per instance, and the string scans JSON and XML build for the V3 tier.
TIER_ROOTS = (
    re.compile(r"kernel::scan_v3:"),
    re.compile(r"kernel::\[tier_amd64\.odin\]::lookup_v3"),
    re.compile(r"kernel::\[tier_amd64\.odin\]::set_v3"),
    re.compile(r"kernel::\[tier_amd64\.odin\]::clmul_prefix_xor"),
    re.compile(r"dsv::(pass_default|pass_with|read_chunk|line_end)_v3:"),
    re.compile(r"json::\w+_v3:"),
    re.compile(r"xml::span_v3:"),
)
# AT&T mnemonics past x86-64-v2. `lzcnt` runs as `bsr` on a CPU without it and answers differently. `tzcnt` is not
# here: LLVM emits it as `rep bsf` for a non-zero input on any CPU, where it runs as `bsf` with the same answer.
BEYOND_V2 = re.compile(r"v\w+|(andn|bextr|blsi|blsmsk|blsr|bzhi|lzcnt|movbe|mulx|pdep|pext|rorx|sarx|shlx|shrx)[wlq]?|pclmul\w*")
# A disassembly line: address, colon, then the mnemonic (raw bytes are not shown).
INSTRUCTION = re.compile(r"^\s+[0-9a-f]+:\s+(\S+)")
# A symbol an instruction names, with the offset into it dropped.
REFERENCE = re.compile(r"<(.+?)(?:\+0x[0-9a-f]+)?>$")


def reach(root: str, callees: dict[str, set[str]], tier: set[str]) -> set[str]:
    """The procedures of `tier` that `root` calls, directly or not, and `root`."""
    seen, todo = {root}, [root]
    while todo:
        for callee in callees.get(todo.pop(), ()):
            if callee in tier and callee not in seen:
                seen.add(callee)
                todo.append(callee)
    return seen


def main() -> int:
    objdump, obj = sys.argv[1], sys.argv[2]
    required = sys.argv[sys.argv.index("--require") + 1] if "--require" in sys.argv else "kernel::scan_v3:"
    text = subprocess.run(
        [objdump, "-d", "--no-show-raw-insn", obj], check=True, capture_output=True, text=True
    ).stdout
    beyond: dict[str, set[str]] = {}
    callers: dict[str, set[str]] = {}
    callees: dict[str, set[str]] = {}
    symbol = ""
    for line in text.splitlines():
        if m := SYMBOL.match(line):
            symbol = m.group(1)
            continue
        if not (m := INSTRUCTION.match(line)):
            continue
        if BEYOND_V2.fullmatch(m.group(1)):
            beyond.setdefault(symbol, set()).add(m.group(1))
        if (ref := REFERENCE.search(line)) and ref.group(1) != symbol:
            callers.setdefault(ref.group(1), set()).add(symbol)
            callees.setdefault(symbol, set()).add(ref.group(1))
    roots = {s for s in beyond.keys() | callers.keys() | {symbol} if any(r.search(s) for r in TIER_ROOTS)}
    tier = set(roots)
    grew = True
    while grew:
        grew = False
        for s in beyond.keys() - tier:
            if callers.get(s) and callers[s] <= tier:
                tier.add(s)
                grew = True
    failed = False
    for s in sorted(beyond.keys() - tier):
        print(f"{obj}: {s} holds {', '.join(sorted(beyond[s]))}")
        failed = True
    reaching = {s for s in roots if any(r in beyond for r in reach(s, callees, tier))}
    if "--inlined" in sys.argv[3:]:
        for s in sorted(roots - reaching):
            print(f"{obj}: tier procedure {s} reaches no instruction past x86-64-v2")
            failed = True
    elif not reaching:
        print(f"{obj}: no tier procedure reaches an instruction past x86-64-v2")
        failed = True
    if not any(required in s for s in roots):
        print(f"{obj}: no {required} procedure in the disassembly")
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
