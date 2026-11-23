"""Fails when a WebAssembly object of `tools/wasm/exports.odin` lacks an exported caller, or a walk that tail calls.

usage: wasm_check.py NM OBJDUMP OBJECT EXPORTS_SOURCE

Every `@(export)` procedure of EXPORTS_SOURCE must be defined in OBJECT, and every walk state `st_value`, for each spec,
each kind of read (no hooks, finder, scanner, builder), with `LAX` (steps and pieces) and without, must be there and
hold a `return_call`, which a walk's `#must_tail` calls become only with the `tail-call` feature.
"""

import itertools
import re
import subprocess
import sys

EXPORT = re.compile(r"@\(export\)\s+(\w+)\s*::", re.M)
FUNCTION = re.compile(r"^[0-9a-f]+ <(.+)>:$")
SPEC = re.compile(r"Walk\(S:\$\$(\d+),")
LAX = re.compile(r"LAX:\$\$(true|false)")
READS = ("No_Hooks", "Finder", "Scanner", "Builder")
SPECS = ("0", "1", "2")
LAXES = ("false", "true")


def main() -> int:
    nm, objdump, obj, source = sys.argv[1:5]
    defined = set(
        subprocess.run([nm, "--defined-only", "--extern-only", obj], check=True, capture_output=True, text=True)
        .stdout.split()
    )
    failed = False
    for name in EXPORT.findall(open(source).read()):
        if name not in defined:
            print(f"{obj}: export {name} is not defined")
            failed = True
    text = subprocess.run([objdump, "-d", obj], check=True, capture_output=True, text=True).stdout
    tail_calling: set[tuple[str, str, str]] = set()
    present: set[tuple[str, str, str]] = set()
    current: tuple[str, str, str] | None = None
    for line in text.splitlines():
        if m := FUNCTION.match(line):
            current = None
            name = m.group(1)
            spec, lax = SPEC.search(name), LAX.search(name)
            if name.startswith("json::st_value:") and spec and lax:
                for read in READS:
                    if f"::{read},LAX:" in name:
                        current = (spec.group(1), read, lax.group(1))
                        present.add(current)
        elif current and "return_call" in line:
            tail_calling.add(current)
    for spec, read, lax in itertools.product(SPECS, READS, LAXES):
        if (spec, read, lax) not in present:
            print(f"{obj}: no st_value walk for spec {spec}, read {read}, LAX {lax}")
            failed = True
        elif (spec, read, lax) not in tail_calling:
            print(f"{obj}: st_value walk for spec {spec}, read {read}, LAX {lax} holds no return_call")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
