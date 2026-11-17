import os
import subprocess
import sys
import time

from tabulate import tabulate

FORMATS = {"gb_per_s": "{:.3f}", "ns": "{:d}", "rss": "{:.1f}"}


def machine():
    """The Odin version, the CPU and the date, on one line."""
    try:
        out = subprocess.run([os.environ.get("ODIN", "odin"), "version"], capture_output=True, text=True).stdout
    except OSError:
        out = ""
    odin = out.split()[-1] if out.split() else ""
    if sys.platform == "darwin":
        cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    else:
        cpu = next((l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")), "")
    return f"odin {odin or 'not found, set ODIN'}, {cpu or 'cpu unknown'}, {time.strftime('%Y-%m-%d')}"


def show(title, headers, rows):
    """Prints a table: a blank line, TITLE, then one line per row, numbers right-aligned. A cell that is None is blank."""
    print(f"\n{title}")
    print(tabulate(rows, headers=headers, floatfmt=".3f", missingval="-", disable_numparse=False, tablefmt="plain"), flush=True)
