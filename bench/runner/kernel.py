import os
import re
import statistics
import sys

from . import guard, probes
from .tables import machine, show

LINE = re.compile(r"sink=(\d+) ns=([\d.]+) units=(\d+)")


def main(rounds, binaries, only, count):
    """Times every case of the kernel lane over interleaved rounds, then counts instructions and cycles per unit from the
    difference between R and 2R reps. Several binaries share each round, so they share the machine's drift."""
    spec = probes.lane_toml("kernel")
    cases = [c for c in spec["case"] if re.search(only, c["name"])]
    binaries = binaries or [str(probes.binary("kernel", "stury"))]
    print(machine())
    print(spec["lane"]["legend"])
    ns, units = {}, {}
    with guard.locked():
        for _ in range(rounds):
            for c in cases:
                for exe in binaries:
                    m = LINE.search(guard.run([exe, c["sub"], str(c["reps"]), str(c["arg"])]).out)
                    ns.setdefault((exe, c["name"]), []).append(float(m.group(2)))
                    units[c["name"]] = int(m.group(3))
        rows = []
        for c in cases:
            for exe in binaries:
                times = ns[exe, c["name"]]
                row = [c["name"] + (f" {os.path.basename(exe)}" if len(binaries) > 1 else ""),
                       statistics.median(times), min(times)]
                if count:
                    cmd = lambda reps: [exe, c["sub"], str(reps), str(c["arg"])]
                    a = [guard.counts(cmd(c["reps"]), ["instructions", "cycles"]) for _ in range(3)]
                    b = [guard.counts(cmd(2 * c["reps"]), ["instructions", "cycles"]) for _ in range(3)]
                    n = c["reps"] * units[c["name"]]
                    ins, cyc = ((statistics.median(x[i] for x in b) - statistics.median(x[i] for x in a)) / n for i in (0, 1))
                    row += [ins, cyc, ins / cyc]
                rows.append(row)
    show("kernel", ["case", "ns", "best ns"] + ["ins", "cyc", "ipc"] * count, rows)
    return 0
