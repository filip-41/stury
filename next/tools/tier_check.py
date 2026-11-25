"""Fails when x86-64 object(s) hold an instruction past x86-64-v2 where only a V2 CPU's code may run: VEX or EVEX,
BMI1 and BMI2 but `tzcnt`, LZCNT, PCLMULQDQ and MOVBE.

usage: tier_check.py OBJDUMP PATH... [--inlined] [--inlined-skip SUBSTR ...] [--require NAME]

Each PATH is an x86-64 `.o` file or a directory of `.o` files (as `-use-separate-modules` writes). Symbol tables and
relocations are parsed across every object to stitch the full cross-object call graph: local/static symbols stay
scoped to their defining object, external/weak symbols link by name across objects, and any function referenced from
data/rodata/tdata relocations (including section-relative `.text+0x...` pointers to object-local procs) is treated as
callable from V2.

The V3 tier is the procedures `lib/base/kernel/tier_amd64.odin`, `dsv/tier_amd64.odin`, `json/strings.odin` and
`xml/text.odin` declare for it, `TIER_ROOTS`, and the procedures only those call (directly or transitively), which at
`-o:none` or `-use-separate-modules` include the kernels `scan_v3` and `pass_*_v3` do not inline. Every other
procedure is held to x86-64-v2, so a callee that a V2 path also reaches fails even though a V3 procedure calls it too.
The disassembly must hold a `scan_v3`, or the procedure `--require` names, and some root that reaches an instruction
past x86-64-v2, so one not read as expected fails instead of passing empty. With `--inlined`, every root (except any
named by `--inlined-skip`) must reach one.
"""

import bisect
import glob
import os
import re
import subprocess
import sys

FILE_HEADER = re.compile(r"^(.+):\tfile format ")
SECTION_HEADER = re.compile(r"^Disassembly of section (.+):$")
SYMBOL = re.compile(r"^[0-9a-f]+ <(.+)>:$")
# `llvm-objdump -t` ELF symbol table entry: addr, 7 flag chars, section, tab, size, name.
SYMTAB_ENTRY = re.compile(r"^([0-9a-f]+)\s(.{7})\s(\S+)\t([0-9a-f]+)\s+(.+)$")
# `llvm-objdump -r` section header and entry.
RELOC_SECTION = re.compile(r"^RELOCATION RECORDS FOR \[(.+)\]:$")
RELOC_TABLE_ENTRY = re.compile(r"^[0-9a-f]+\s+(\S+)\s+(.+)$")
# Inline relocation line in `llvm-objdump -dr`.
DIS_RELOC = re.compile(r"^\s+[0-9a-f]+:\s+(R_X86_64_\S+)\s+(.+)$")
ADDEND = re.compile(r"([+-])0x([0-9a-f]+)$")

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
BEYOND_V2 = re.compile(
    r"v\w+|(andn|bextr|blsi|blsmsk|blsr|bzhi|lzcnt|movbe|mulx|pdep|pext|rorx|sarx|shlx|shrx)[wlq]?|pclmul\w*"
)
# A disassembly line: address, colon, then the mnemonic (raw bytes are not shown).
INSTRUCTION = re.compile(r"^\s+[0-9a-f]+:\s+(\S+)")
# A symbol an instruction names, with the offset into it dropped.
REFERENCE = re.compile(r"<(.+?)(?:\+0x[0-9a-f]+)?>$")

# Sections whose relocations to a function make it indirectly callable from V2.
DATA_RELOC_PREFIXES = (".data", ".rodata", ".tdata", ".init_array", ".fini_array", ".ctors", ".dtors")

# Canonical symbol node: `("", name)` for global/weak/external symbols, `(obj, name)` for local/static symbols.
Node = tuple[str, str]


def parse_args(argv: list[str]) -> tuple[str, list[str], bool, list[str], str]:
    if len(argv) < 3:
        raise SystemExit("usage: tier_check.py OBJDUMP PATH... [--inlined] [--inlined-skip SUBSTR ...] [--require NAME]")
    objdump = argv[1]
    inlined = False
    inlined_skips: list[str] = []
    required = "kernel::scan_v3:"
    paths: list[str] = []
    i = 2
    while i < len(argv):
        arg = argv[i]
        if arg == "--inlined":
            inlined = True
        elif arg == "--inlined-skip":
            if i + 1 >= len(argv):
                raise SystemExit("--inlined-skip takes a root substring")
            i += 1
            inlined_skips.append(argv[i])
        elif arg == "--require":
            if i + 1 >= len(argv):
                raise SystemExit("--require takes a procedure name")
            i += 1
            required = argv[i]
        elif arg.startswith("--"):
            raise SystemExit(f"unknown option: {arg}")
        else:
            paths.append(arg)
        i += 1
    objs: list[str] = []
    for path in paths:
        if os.path.isdir(path):
            found = sorted(glob.glob(os.path.join(path, "*.o")))
            if not found:
                raise SystemExit(f"{path}: no .o files found")
            objs.extend(found)
        else:
            objs.append(path)
    if not objs:
        raise SystemExit("no object files provided")
    return objdump, objs, inlined, inlined_skips, required


def strip_addend(value: str) -> tuple[str, int]:
    """Splits a relocation target like `foo-0x4` or `.text+0x120` into `(symbol, addend)`."""
    if m := ADDEND.search(value):
        sign = -1 if m.group(1) == "-" else 1
        return value[: m.start()], sign * int(m.group(2), 16)
    return value, 0


def resolve_node(obj: str, name: str, local_syms: dict[str, set[str]]) -> Node:
    if name in local_syms.get(obj, ()):
        return (obj, name)
    return ("", name)


def resolve_section_addr(
    obj: str,
    sec: str,
    reloc_type: str,
    addend: int,
    text_ranges: dict[tuple[str, str], tuple[list[int], list[tuple[int, int, Node]]]],
    *,
    is_code: bool = True,
) -> Node | None:
    entry = text_ranges.get((obj, sec))
    if not entry:
        return None
    addr = addend + 4 if is_code and reloc_type in ("R_X86_64_PC32", "R_X86_64_PLT32") else addend
    starts, spans = entry
    idx = bisect.bisect_right(starts, addr) - 1
    if idx >= 0:
        lo, hi, node = spans[idx]
        if lo <= addr < max(hi, lo + 1):
            return node
    return None


def fmt_node(node: Node) -> str:
    obj, name = node
    return f"{os.path.basename(obj)}:{name}" if obj else name


def reach(root: Node, callees: dict[Node, set[Node]], tier: set[Node]) -> set[Node]:
    """The procedures of `tier` that `root` calls, directly or not, and `root`."""
    seen, todo = {root}, [root]
    while todo:
        for callee in callees.get(todo.pop(), ()):
            if callee in tier and callee not in seen:
                seen.add(callee)
                todo.append(callee)
    return seen


def analyze(
    objdump: str,
    objs: list[str],
    inlined: bool,
    required: str,
    inlined_skips: list[str] | None = None,
) -> tuple[int, list[str]]:
    skips = inlined_skips or []
    # 1. Symbol tables: distinguish local (object-scoped) vs global/weak (cross-object) text symbols and address spans.
    sym_out = subprocess.run([objdump, "-t", *objs], check=True, capture_output=True, text=True).stdout
    local_syms: dict[str, set[str]] = {}
    defined_funcs: set[Node] = set()
    defined_in: dict[Node, str] = {}
    raw_ranges: dict[tuple[str, str], list[tuple[int, int, Node]]] = {}
    cur_obj = objs[0]
    for line in sym_out.splitlines():
        if m := FILE_HEADER.match(line):
            cur_obj = m.group(1)
            continue
        if not (m := SYMTAB_ENTRY.match(line)):
            continue
        addr_hex, flags, sec, size_hex, name = m.groups()
        if sec in ("*UND*", "*ABS*") or flags[5] == "d":
            continue
        if sec.startswith(".text") and (flags[6] == "F" or not name.startswith(".L")):
            is_local = flags[0] == "l"
            if is_local:
                local_syms.setdefault(cur_obj, set()).add(name)
            node = (cur_obj, name) if is_local else ("", name)
            defined_funcs.add(node)
            defined_in.setdefault(node, cur_obj)
            addr = int(addr_hex, 16)
            size = int(size_hex, 16)
            raw_ranges.setdefault((cur_obj, sec), []).append((addr, addr + size, node))
    text_ranges: dict[tuple[str, str], tuple[list[int], list[tuple[int, int, Node]]]] = {}
    for key, spans in raw_ranges.items():
        spans.sort(key=lambda item: (item[0], item[1]))
        text_ranges[key] = ([s[0] for s in spans], spans)

    callers: dict[Node, set[Node]] = {}
    callees: dict[Node, set[Node]] = {}

    # 2. Data/rodata/tdata relocations: any function whose address escapes into a data table is treated as V2-callable.
    # LLVM lowers pointers to object-local functions as `R_X86_64_64 .text+0x...`, so resolve section-relative `.text`
    # relocations too (skipping only `.rodata` `R_X86_64_PC32` entries, which are switch jump tables).
    rel_out = subprocess.run([objdump, "-r", *objs], check=True, capture_output=True, text=True).stdout
    cur_obj = objs[0]
    cur_rel_sec = ""
    for line in rel_out.splitlines():
        if m := FILE_HEADER.match(line):
            cur_obj = m.group(1)
            cur_rel_sec = ""
            continue
        if m := RELOC_SECTION.match(line):
            cur_rel_sec = m.group(1)
            continue
        if not cur_rel_sec.startswith(DATA_RELOC_PREFIXES):
            continue
        if not (m := RELOC_TABLE_ENTRY.match(line)):
            continue
        reloc_type, value = m.group(1), m.group(2).strip()
        raw_target, addend = strip_addend(value)
        target: Node | None = None
        if raw_target.startswith(".text"):
            if cur_rel_sec.startswith(".rodata") and reloc_type == "R_X86_64_PC32":
                continue
            target = resolve_section_addr(cur_obj, raw_target, reloc_type, addend, text_ranges, is_code=False)
        elif not raw_target.startswith("."):
            cand = resolve_node(cur_obj, raw_target, local_syms)
            if cand in defined_funcs:
                target = cand
        if target is not None:
            callers.setdefault(target, set()).add(("<data>", cur_rel_sec))

    # 3. Disassembly + inline relocations: record beyond-V2 instructions and intra-/cross-object call edges.
    # Buffer any `<ref>` on an instruction line and drop it if a relocation follows on the next line, so relocated
    # zero-displacement calls/tail-jumps never add phantom edges to the adjacent function.
    dis_out = subprocess.run(
        [objdump, "-dr", "--no-show-raw-insn", *objs], check=True, capture_output=True, text=True
    ).stdout
    beyond: dict[Node, set[str]] = {}
    cur_obj = objs[0]
    current: Node | None = None
    pending_ref: tuple[Node, Node] | None = None

    def flush_pending() -> None:
        nonlocal pending_ref
        if pending_ref is not None:
            src_node, dst_node = pending_ref
            callers.setdefault(dst_node, set()).add(src_node)
            callees.setdefault(src_node, set()).add(dst_node)
            pending_ref = None

    for line in dis_out.splitlines():
        if m := FILE_HEADER.match(line):
            flush_pending()
            cur_obj = m.group(1)
            current = None
            continue
        if SECTION_HEADER.match(line):
            flush_pending()
            current = None
            continue
        if m := SYMBOL.match(line):
            sym_name = m.group(1)
            sym_node = resolve_node(cur_obj, sym_name, local_syms)
            if sym_name.startswith(".L") and sym_node not in defined_funcs:
                continue
            flush_pending()
            current = sym_node
            defined_funcs.add(current)
            defined_in.setdefault(current, cur_obj)
            continue
        if current is None:
            continue
        if m := DIS_RELOC.match(line):
            pending_ref = None
            reloc_type, value = m.group(1), m.group(2).strip()
            raw_target, addend = strip_addend(value)
            target = (
                resolve_section_addr(cur_obj, raw_target, reloc_type, addend, text_ranges, is_code=True)
                if raw_target.startswith(".text")
                else resolve_node(cur_obj, raw_target, local_syms)
            )
            if target is not None and target != current:
                callers.setdefault(target, set()).add(current)
                callees.setdefault(current, set()).add(target)
            continue
        if not (m := INSTRUCTION.match(line)):
            continue
        flush_pending()
        if BEYOND_V2.fullmatch(m.group(1)):
            beyond.setdefault(current, set()).add(m.group(1))
        if ref := REFERENCE.search(line):
            target = resolve_node(cur_obj, ref.group(1), local_syms)
            if target != current:
                pending_ref = (current, target)
    flush_pending()

    # 4. Fixed-point tier set: roots plus every defined function whose callers are exclusively inside `tier`.
    roots = {n for n in defined_funcs if any(r.search(n[1]) for r in TIER_ROOTS)}
    tier = set(roots)
    grew = True
    while grew:
        grew = False
        for n in defined_funcs - tier:
            if callers.get(n) and callers[n] <= tier:
                tier.add(n)
                grew = True

    errors: list[str] = []
    label = objs[0] if len(objs) == 1 else os.path.dirname(objs[0]) or "."
    for n in sorted(beyond.keys() - tier):
        where = defined_in.get(n, label)
        errors.append(f"{where}: {fmt_node(n)} holds {', '.join(sorted(beyond[n]))}")

    reaching = {n for n in roots if any(r in beyond for r in reach(n, callees, tier))}
    if inlined:
        skipped = {n for n in roots if any(pat in n[1] for pat in skips)}
        for pat in skips:
            if not any(pat in n[1] for n in roots):
                errors.append(f"{label}: --inlined-skip {pat!r} matched no tier root")
        for n in sorted(roots - reaching - skipped):
            where = defined_in.get(n, label)
            errors.append(f"{where}: tier procedure {fmt_node(n)} reaches no instruction past x86-64-v2")
    elif not reaching:
        errors.append(f"{label}: no tier procedure reaches an instruction past x86-64-v2")
    if not any(required in n[1] for n in roots):
        errors.append(f"{label}: no {required} procedure in the disassembly")
    return (1 if errors else 0), errors


def main() -> int:
    objdump, objs, inlined, inlined_skips, required = parse_args(sys.argv)
    rc, errors = analyze(objdump, objs, inlined, required, inlined_skips)
    for err in errors:
        print(err)
    return rc


if __name__ == "__main__":
    sys.exit(main())
