#!/usr/bin/env python3
"""Runs smoke.sh and fails when a case fails that smoke.floor does not list.

    python3 cmd/stury/test/smoke_floor.py [build/stury] [--write]

smoke.floor names the cases that fail today, one per line. A case that passes again may stay listed, and `--write`
records this run's failures.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FLOOR = os.path.join(HERE, "smoke.floor")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    done = subprocess.run(["sh", os.path.join(HERE, "smoke.sh"), os.path.abspath(args[0] if args else "build/stury")],
                          capture_output=True, text=True, errors="replace")
    if not any(line.startswith("stury CLI smoke:") for line in done.stdout.splitlines()):
        sys.exit(f"smoke.sh ended without its summary line:\n{(done.stdout + done.stderr)[-2000:]}")
    failing = sorted({line[5:].split(":")[0] for line in done.stdout.splitlines() if line.startswith("FAIL ")})
    if "--write" in sys.argv:
        with open(FLOOR, "w") as file:
            file.writelines(name + "\n" for name in failing)
        return
    with open(FLOOR) as file:
        known = set(file.read().split())
    new = [name for name in failing if name not in known]
    print(f"smoke: {len(failing)} failing, {len(known)} listed in smoke.floor")
    if new:
        lines = done.stdout.splitlines()
        for i, line in enumerate(lines):
            if line.startswith("FAIL ") and line[5:].split(":")[0] in new:
                print("\n".join(lines[i:i + 3]))
        sys.exit("failing and not in smoke.floor: " + " ".join(new))


if __name__ == "__main__":
    main()
