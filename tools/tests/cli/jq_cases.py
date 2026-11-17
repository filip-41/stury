"""The case files of the jq suite: jq's own test files and cli.tsv, and the run of a cli.tsv row."""

import json
import os
import re
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

from capped import TIMEOUT, outcome

CASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases")
SUITE = os.path.join(CASES, "jq-1.8.2")
MODULE_DIR = os.path.join(CASES, "modules")
CLI_TSV = os.path.join(CASES, "cli.tsv")


def parse_suite(path):
    """jq's test file as cases, read the way jq's run-tests reads it: blank and `#` lines between tests,
    `%%FAIL [IGNORE MSG]` before a program that must not compile (then its message, then lines up to a
    blank one), otherwise the program, one input line and the expected outputs up to a blank or `#` line."""
    lines = open(path, encoding="utf-8", errors="surrogateescape").read().split("\n")
    skip = lambda s: s.lstrip(" \t") == "" or s.lstrip(" \t").startswith("#")
    cases, i, fail = [], 0, None
    while i < len(lines):
        line = lines[i]
        i += 1
        if skip(line):
            continue
        if line in ("%%FAIL", "%%FAIL IGNORE MSG"):
            fail = "ignore" if line.endswith("MSG") else "msg"
            continue
        case = {"file": os.path.basename(path), "line": i, "prog": line, "fail": fail}
        if fail:
            case["msg"] = lines[i] if i < len(lines) else ""
            while i < len(lines) and lines[i] != "":
                i += 1
        else:
            case["input"] = lines[i] if i < len(lines) else ""
            i += 1
            case["want"] = []
            while i < len(lines) and not skip(lines[i]):
                case["want"].append(lines[i])
                i += 1
        fail = None
        cases.append(case)
    return cases


def joined(cell):
    """A cell written as {"cat": [text or [unit, count], ...]} is the concatenation of its parts, a unit repeated count times."""
    if isinstance(cell, dict) and "cat" in cell:
        return "".join(p if isinstance(p, str) else p[0] * p[1] for p in cell["cat"])
    return cell


def parse_cli(path=CLI_TSV):
    """cli.tsv: area, then as JSON the arguments, stdin, files and, once recorded, jq's exit status, stdout and
    stderr. The arguments may be {"env": {NAME: VALUE}, "args": [...]}, to run with those variables set, and
    {"stdout": "closed", "args": [...]} to run with no stdout open. An area starting with `!` marks a case too
    deep for ThreadSanitizer's stack."""
    cases = []
    for n, row in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if not row or row.startswith("#"):
            continue
        area, *cols = row.split("\t")
        slow = area.startswith("!")
        args, stdin, files, *want = [json.loads(c) for c in cols]
        stdin, files, want = joined(stdin), {k: joined(v) for k, v in files.items()}, [joined(w) for w in want]
        env, closed = {}, False
        if isinstance(args, dict):
            env, closed, args = args.get("env", {}), args.get("stdout") == "closed", args["args"]
        cases.append({"line": n, "area": area.lstrip("!"), "args": args, "env": env, "closed": closed, "stdin": stdin,
                      "files": files, "want": want, "row": row, "slow": slow})
    return cases


def jq_args(args):
    """`args` as jq takes them: without the options only stury has (--max-depth, --from, --to) and their values."""
    out, k = [], 0
    while k < len(args):
        if args[k] in ("--max-depth", "--from", "--to"):
            k += 1
        else:
            out.append(args[k])
        k += 1
    return out


def run_cli(binary, case, reference=False):
    """The case's command line in a scratch directory holding its files: exit status, stdout, stderr. `$DIR`
    in an argument or a variable is that directory, and it (or its real path) in the output reads `$DIR`; a
    variable set to null is unset. `reference` runs jq, which takes no option only stury has."""
    enc = lambda s: s.encode("utf-8", "surrogateescape")
    with tempfile.TemporaryDirectory() as d:
        for name, content in case["files"].items():
            os.makedirs(os.path.dirname(os.path.join(d, name)), exist_ok=True)
            with open(os.path.join(d, name), "wb") as f:
                f.write(enc(content))
        args = jq_args(case["args"]) if reference else case["args"]
        args = [a.replace("$DIR", d) for a in args]
        env = {**os.environ, **{k: v.replace("$DIR", d) for k, v in case["env"].items() if v is not None}}
        for k in [k for k, v in case["env"].items() if v is None]:
            env.pop(k, None)
        real = enc(os.path.realpath(d))
        # dash, /bin/sh on Debian and Ubuntu, drops a variable whose name is not a shell name.
        if os.name == "nt" or not all(re.fullmatch("[A-Za-z_][A-Za-z0-9_]*", k) for k in case["env"]):
            argv, cwd = [binary] + args, d
        else:
            # sh enters the directory: a cwd makes subprocess fork this process, which holds the suite's big texts.
            argv, cwd = ["/bin/sh", "-c", 'cd "$0" && exec "$@"' + (" >&-" if case["closed"] else ""), d, binary, *args], None
        code, out, err = outcome(argv, enc(case["stdin"]), TIMEOUT, cwd=cwd, env=env)
        unreal = lambda b: b.replace(real, b"$DIR").replace(enc(d), b"$DIR")
        return code, unreal(out), unreal(err)


def record(jq):
    """Writes jq's answers into cli.tsv, for the rows that lack them or differ."""
    dec = lambda b: b.decode("utf-8", "surrogateescape")
    lines = open(CLI_TSV, encoding="utf-8").read().split("\n")
    cases = parse_cli()
    with ThreadPoolExecutor(min(8, os.cpu_count() or 1)) as pool:
        answers = list(pool.map(lambda case: run_cli(jq, case, reference=True), cases))
    for case, (code, out, err) in zip(cases, answers):
        if case["want"] and case["want"][0] is None:
            continue
        # A row whose answer is unchanged keeps its bytes, however its strings are escaped.
        if case["want"][:3] != [code, dec(out), dec(err)]:
            cols = case["row"].split("\t")
            cols[4:7] = [json.dumps(code), json.dumps(dec(out)), json.dumps(dec(err))]
            lines[case["line"] - 1] = "\t".join(cols)
    open(CLI_TSV, "w", encoding="utf-8").write("\n".join(lines))


if __name__ == "__main__":
    jq = sys.argv[1] if len(sys.argv) > 1 else "jq"
    version = os.popen(f"{jq} --version").read().strip()
    if version != "jq-1.8.2":
        sys.exit(f"recording needs jq 1.8.2, found {version or 'none'}")
    record(jq)
