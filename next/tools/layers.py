#!/usr/bin/env python3
"""Checks the layer direction of layout.md by path: lib/base only other lib/base packages, lib/core only lib/base and
itself, lib/ops only lib/core and lib/base and never another lib/ops package, lib/schema only the layers below it,
and nothing under lib/ imports a package above lib/ or testkit. Above lib/: every top-level package that TOP_EDGES
does not name is a format, and a format and host import only the layers below, a format never another package above
lib/. The named packages (the facade, the registry, the query frontends, the C ABI, the CLI) may import the formats,
host and each other as TOP_EDGES says, so cli uses engine like any library caller. Test packages and tools may import
anything inside next/. An import that leaves next/ fails everywhere."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LAYERS = ["lib/base", "lib/core", "lib/ops", "lib/schema", "lib/query"]
# The top-level packages above the formats. Any other top-level directory is a format, which imports only the
# layers below lib/query. Query frontends (`jq`, `jsonpath`) import only `lib/*` (no formats, no host).
QUERY_FRONTENDS = {"jq", "jsonpath"}
TOP_EDGES = {
    "stury": {"engine", "jq", "jsonpath"},
    "engine": set(),
    "cli": {"engine", "host", "jq", "jsonpath"},
    "capi": {"stury", "engine"},
}
HOST = "host"
IMPORT = re.compile(r'^\s*import\s+(?:\w+\s+)?"([^"]+)"|^\s*(?:\w+\s+)?"(stury:[^"]+)"', re.M)


def layer(rel: str) -> int:
    for i, prefix in enumerate(LAYERS):
        if rel == prefix or rel.startswith(prefix + "/"):
            return i
    return len(LAYERS)


def is_test(rel: str) -> bool:
    parts = rel.split("/")
    return "test" in parts or parts[0] in ("testkit", "tools")


def is_format(rel: str) -> bool:
    return layer(rel) == len(LAYERS) and rel != HOST and rel not in TOP_EDGES and rel not in QUERY_FRONTENDS


def allowed(src: str, dst: str) -> bool:
    if is_test(src):
        return True
    if dst == "testkit" or dst.startswith("testkit/"):
        return False
    s, d = layer(src), layer(dst)
    if s < len(LAYERS):
        if s == 0:
            return d == 0
        # The ops are independent consumers of the core, so one never builds on another.
        return d < s or d == s and LAYERS[s] != "lib/ops"
    if src in QUERY_FRONTENDS:
        return d < len(LAYERS)
    if src in TOP_EDGES:
        return d < len(LAYERS) or dst == HOST or dst in TOP_EDGES[src] or is_format(dst)
    # A format or host: only the layers below lib/query.
    return d < len(LAYERS) - 1


def main() -> int:
    bad = []
    for path in sorted(ROOT.rglob("*.odin")):
        rel_file = path.relative_to(ROOT).as_posix()
        if rel_file.startswith("build/"):
            continue
        src = path.parent.relative_to(ROOT).as_posix()
        for m in IMPORT.finditer(path.read_text()):
            target = m.group(1) or m.group(2)
            if target.startswith(("core:", "base:", "vendor:")):
                continue
            if not target.startswith("stury:"):
                bad.append(f"{rel_file}: {target} resolves outside the stury collection")
                continue
            dst = target[len("stury:"):]
            if not allowed(src, dst):
                bad.append(f"{rel_file}: {src} may not import {dst}")
    for line in bad:
        print(line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
