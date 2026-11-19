import argparse
import os
import sys

from . import cases, fixtures, kernel, lane, probes, schema

TIMED_LANES = ["doc", "paths", "typed", "records", "write", "edit", "model"]
CLI_LANES = ["cli", "files"]
ALL_LANES = ["kernel", *TIMED_LANES, "schema", *CLI_LANES]
BUILT_LANES = [lane for lane in ALL_LANES if lane not in CLI_LANES]


def rounds(text):
    n = int(text)
    if n < 1:
        raise argparse.ArgumentTypeError("rounds must be a whole number of at least 1")
    return n


def parser():
    p = argparse.ArgumentParser(prog="bench")
    sub = p.add_subparsers(dest="command", required=True)
    fix = sub.add_parser("fixtures", help="fetch the downloaded fixtures and write the generated ones")
    fix.add_argument("--check", action="store_true", help="write nothing, fail when a generated fixture's hash is not pinned")
    fix.add_argument("names", nargs="*", metavar="NAME", help="write only these generated fixtures")
    build = sub.add_parser("build", help="build the programs the lanes run")
    build.add_argument("lanes", nargs="*", choices=BUILT_LANES, metavar="LANE")
    for name in ALL_LANES:
        lp = sub.add_parser(name, help=f"run the {name} lane")
        lp.add_argument("--rounds", type=rounds, default=os.environ.get("ROUNDS") or 5)
        lp.add_argument("--no-build", action="store_true", help="run the programs as they are built")
        if name == "kernel":
            lp.add_argument("--binary", action="append", default=[], help="another kernel program to time beside this one")
            lp.add_argument("--cases", default=os.environ.get("CASES", "."), help="regex that keeps the cases whose name matches")
            lp.add_argument("--no-count", action="store_true", default=os.environ.get("COUNT") == "0")
        elif name in CLI_LANES:
            lp.add_argument("--runs", type=int, default=int(os.environ.get("RUNS") or 2), help="timings per tool in a round")
            if name == "cli":
                lp.add_argument("--suite", choices=["jq", "csv", "xml", "yaml", "html", "toml"], default="jq")
            lp.add_argument("--cases", default=os.environ.get("CASES", "."), help="regex that keeps the cases whose name matches")
        else:
            lp.add_argument("--arms", default=os.environ.get("ARMS"), help="comma-separated arms to run")
            lp.add_argument("names", nargs="*", metavar="ROW", help="run only these rows, by label or fixture")
    return p


def main():
    args = parser().parse_args()
    if args.command == "fixtures":
        sys.exit(fixtures.generate(args.names, args.check))
    if args.command == "build":
        sys.exit(0 if probes.build(args.lanes or BUILT_LANES) else 1)
    if args.command not in CLI_LANES and not args.no_build and not probes.build([args.command]):
        sys.exit(1)
    arms = args.arms.split(",") if getattr(args, "arms", None) else None
    n = int(args.rounds)
    if args.command == "kernel":
        sys.exit(kernel.main(n, args.binary, args.cases, not args.no_count))
    if args.command == "schema":
        sys.exit(schema.main(n, args.names, arms))
    if args.command in CLI_LANES:
        sys.exit(cases.main(args.command, n, args.runs, getattr(args, "suite", None), args.cases))
    sys.exit(lane.main(args.command, n, args.names, arms))
