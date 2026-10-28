#!/usr/bin/env python3
"""The CLI reaches the formats through core and its format registry.

Every `.odin` file under `cmd/` may import `core` and `host`. Only the registry,
`cmd/stury/formats.odin`, imports a format package (`json`, `csv`), and no file
imports a format's subpackage (`json/scan`, `json/encode`, ...). ALLOWED names the
files that still do, each with the imports it keeps; an entry that no longer
needs its import is reported too, so the list only shrinks.

No file under `cmd/` imports `core:fmt`, which the binary would link whole: messages are built by
`cmd/stury/message`.

Exit codes: 0 clean, 1 a file breaks the rule or an entry is stale, 2 nothing scanned.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FORMATS = ("json", "csv")
REGISTRY = "cmd/stury/formats.odin"

ALLOWED = {
    "cmd/stury/check.odin": {"json"},
    "cmd/stury/explain.odin": {"json"},
    "cmd/stury/fmt.odin": {"json", "csv"},
    "cmd/stury/input.odin": {"json"},
    "cmd/stury/input_csv.odin": {"csv"},
    "cmd/stury/input_fault.odin": {"json"},
    "cmd/stury/input_stream.odin": {"json"},
    "cmd/stury/load_values.odin": {"json"},
    "cmd/stury/main.odin": {"json"},
    "cmd/stury/options.odin": {"json"},
    "cmd/stury/output_cells.odin": {"csv"},
    "cmd/stury/pool.odin": {"json"},
    "cmd/stury/print.odin": {"json"},
    "cmd/stury/record_scan.odin": {"json"},
    "cmd/stury/root_pieces.odin": {"json"},
    "cmd/stury/root_spine.odin": {"json"},
    "cmd/stury/scan_cells.odin": {"csv", "json/scan"},
    "cmd/stury/scan_inputs.odin": {"json"},
    "cmd/stury/jq/compare.odin": {"json"},
    "cmd/stury/jq/encode.odin": {"json"},
    "cmd/stury/jq/natives.odin": {"json"},
    "cmd/stury/jq/read.odin": {"json"},
    "cmd/stury/jq/value.odin": {"json"},
}

IMPORT = re.compile(r'^import\s+(?:\w+\s+)?"([^"]+)"', re.M)


def format_imports(path: pathlib.Path) -> set[str]:
    found = set()
    for spec in IMPORT.findall(path.read_text()):
        if ":" in spec:
            continue
        target = (path.parent / spec).resolve()
        try:
            rel = target.relative_to(ROOT).as_posix()
        except ValueError:
            continue
        if rel.split("/")[0] in FORMATS:
            found.add(rel)
    return found


def main() -> int:
    files = sorted((ROOT / "cmd").rglob("*.odin"))
    if not files:
        print("cli_imports: no files under cmd/", file=sys.stderr)
        return 2
    bad = []
    for path in files:
        name = path.relative_to(ROOT).as_posix()
        got = format_imports(path)
        allowed = set(FORMATS) if name == REGISTRY else ALLOWED.get(name, set())
        if re.search(r'^import\s+(?:\w+\s+)?"core:fmt"', path.read_text(), re.M):
            bad.append(f"{name}: imports core:fmt: build the text with cmd/stury/message")
        for spec in sorted(got - allowed):
            bad.append(f"{name}: imports {spec}: reach it through core or {REGISTRY}")
        for spec in sorted(ALLOWED.get(name, set()) - got):
            bad.append(f"{name}: no longer imports {spec}: drop it from ALLOWED in tools/cli_imports.py")
    for name in sorted(set(ALLOWED) - {p.relative_to(ROOT).as_posix() for p in files}):
        bad.append(f"{name}: gone: drop it from ALLOWED in tools/cli_imports.py")
    for line in bad:
        print(line, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
