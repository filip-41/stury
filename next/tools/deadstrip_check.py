"""Fails when a constant-spec build links any read of another entry point, or no build at all.

usage: deadstrip_check.py NM OBJECT

OBJECT is a build of `tools/deadstrip`, whose only read is one `json.build` of one spec. Its `json::` symbols are one
spec's walk states, its hook set and its handle; a read left on the handle would link the reads of every spec and
entry point, which the names below catch without pinning the walk's state count.
"""

import subprocess
import sys

# The reads of another entry point, and the handle's four read wrappers, which a `Format` that carries its reads
# links even when only one is called. A walk state added to the spec is none of them.
OTHER_READS = (
    "json::validate_as:",
    "json::find_as:",
    "json::scan_as:",
    "json::validate_of",
    "json::build_of",
    "json::find_of",
    "json::scan_of",
)


def main() -> int:
    nm, obj = sys.argv[1], sys.argv[2]
    defined = subprocess.run([nm, "--defined-only", obj], check=True, capture_output=True, text=True).stdout
    # Mach-O prefixes a symbol with an underscore, ELF does not.
    names = [line.split(maxsplit=2)[-1].removeprefix("_") for line in defined.splitlines() if line.strip()]
    json = [name for name in names if name.startswith("json::")]
    builds = [name for name in json if name.startswith("json::build_as:")]
    if len(builds) == 0:
        print(f"{obj}: no json::build_as, so the probe linked no read")
        return 1
    if len(builds) > 1:
        print(f"{obj}: {len(builds)} json::build_as, so the probe linked more than one spec")
        return 1
    other = [name for name in json if any(name.startswith(read) for read in OTHER_READS)]
    if other:
        print(f"{obj}: a constant-spec build links other reads: {' '.join(other[:4])}")
        return 1
    return 0


sys.exit(main())
