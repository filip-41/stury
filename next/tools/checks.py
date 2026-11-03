#!/usr/bin/env python3
"""Checks over the tree: its lean size, its import order, its public surface, and the words in core.

Run from next/: `python3 tools/checks.py size`, `imports`, `surface` or `words`.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The library packages, and the order imports of them take. json and dsv share the last rank.
PACKAGES = ["core/spell", "core", "core/kernel", "core/compose", "core/build", "core/typed", "core/write", "json", "dsv"]
RANK = {"core/spell": 0, "core": 1, "core/kernel": 2, "core/compose": 2, "core/build": 3, "core/typed": 4, "core/write": 5, "json": 6, "dsv": 6}
FORMATS = {"json", "dsv"}

LEAN_BUDGET = 20_500

# core's format-neutral packages name no format's concept in their code. core/kernel is left out: its tables are a byte
# shuffle's.
NEUTRAL = ["core/spell", "core", "core/compose", "core/build", "core/typed", "core/write"]
FORMAT_WORD = re.compile(r"(?<![a-z])(header|table|cell|delimiter)s?(?![a-z])")

DECL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(::|:=|:)")


def odin_files(directory):
    """Every .odin file under `directory`, in path order."""
    out = []
    for base, dirs, files in os.walk(directory):
        # The build output is `next/build` only: a package named `build` holds source.
        dirs[:] = sorted(
            d for d in dirs if d != "__pycache__" and not (d == "build" and base == ROOT)
        )
        for name in sorted(files):
            if name.endswith(".odin"):
                out.append(os.path.join(base, name))
    return out


def package_files(package):
    """The .odin files directly in a package directory, never a subpackage's."""
    directory = os.path.join(ROOT, package)
    return [
        os.path.join(directory, name)
        for name in sorted(os.listdir(directory))
        if name.endswith(".odin")
    ]


def lean_lines(path):
    count = 0
    with open(path, encoding="utf-8") as file:
        for line in file:
            text = line.strip()
            if text and not text.startswith("//"):
                count += 1
    return count


def size():
    total = 0
    for package in PACKAGES:
        count = sum(lean_lines(path) for path in package_files(package))
        total += count
        print(f"{package:<12} {count:>6}")
    print(f"{'sum':<12} {total:>6} of {LEAN_BUDGET}")
    return 0 if total <= LEAN_BUDGET else 1


def strip_code(line, block):
    """Returns the line outside strings and comments, and whether a block comment is open."""
    out = []
    i = 0
    while i < len(line):
        if block:
            end = line.find("*/", i)
            if end < 0:
                return "".join(out), True
            i = end + 2
            block = False
            continue
        c = line[i]
        if c == "/" and line.startswith("//", i):
            break
        if c == "/" and line.startswith("/*", i):
            block = True
            i += 2
            continue
        if c in "\"'":
            quote = c
            i += 1
            while i < len(line):
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out), block


IMPORT = re.compile(r'^\s*import\s+(?:[A-Za-z_][A-Za-z0-9_]*\s+)?"([^"]+)"\s*$')
IMPORT_GROUP = re.compile(r"^\s*import\s*\(\s*$")
GROUPED = re.compile(r'^\s*(?:[A-Za-z_][A-Za-z0-9_]*\s+)?"([^"]+)"\s*,?\s*$')


def imports_in(path):
    """Yields the import paths of a file, in file order."""
    grouped = False
    with open(path, encoding="utf-8") as file:
        for line in file:
            if grouped:
                if line.strip() == ")":
                    grouped = False
                    continue
                found = GROUPED.match(line)
                if found:
                    yield found.group(1)
                continue
            if IMPORT_GROUP.match(line):
                grouped = True
                continue
            found = IMPORT.match(line)
            if found:
                yield found.group(1)


def resolve(path, source):
    """Returns the package a relative import names, as a path under next/, or None for a collection import."""
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", path):
        return None
    target = os.path.normpath(os.path.join(os.path.dirname(source), path))
    if os.path.commonpath([ROOT, target]) != ROOT:
        return "<outside>"
    return os.path.relpath(target, ROOT)


def importer_package(source):
    rel = os.path.relpath(os.path.dirname(source), ROOT)
    return rel


def imports():
    errors = []
    for source in odin_files(ROOT):
        here = importer_package(source)
        last = -1
        for path in imports_in(source):
            target = resolve(path, source)
            if target == "<outside>":
                errors.append(f"{os.path.relpath(source, ROOT)}: imports {path!r} outside next/")
                continue
            if target is None:
                continue
            tag = os.path.relpath(source, ROOT)
            rank = RANK.get(target)
            if rank is not None:
                if rank < last:
                    errors.append(f"{tag}: imports {target!r} out of order")
                last = max(last, rank)
                here_rank = RANK.get(here)
                if here_rank is not None and rank >= here_rank:
                    errors.append(f"{tag}: imports {target!r}, which does not rank below {here!r}")
                if here in FORMATS and target in FORMATS and here != target:
                    errors.append(f"{tag}: {here} imports {target}")
    for line in errors:
        print(line)
    return 1 if errors else 0


ATTR = re.compile(r"^\s*@\((.*)\)\s*$")


def declarations(path):
    """Yields the public top-level names of a file."""
    # Each open brace is True for a `when` block, which holds top-level declarations.
    open_braces = []
    pending_private = False
    block = False
    with open(path, encoding="utf-8") as file:
        for line in file:
            code, block = strip_code(line, block)
            stripped = code.strip()
            attr = ATTR.match(code)
            if attr and not open_braces:
                attributes = {part.strip() for part in attr.group(1).split(",")}
                if any(a == "private" or a.startswith("private ") for a in attributes):
                    pending_private = True
                continue
            top = all(open_braces)
            found = DECL.match(code) if top else None
            if found:
                name = found.group(1)
                if not pending_private and not name.startswith("_"):
                    yield name
                pending_private = False
            elif stripped and not stripped.startswith("@"):
                pending_private = False
            when = re.match(r"^(when|else)\b", stripped) is not None
            for c in code:
                if c == "{":
                    open_braces.append(when and all(open_braces))
                elif c == "}":
                    if open_braces:
                        open_braces.pop()
    if open_braces:
        raise ValueError(f"{path}: unbalanced braces")


def words():
    found = 0
    for package in NEUTRAL:
        for path in package_files(package):
            block = False
            with open(path, encoding="utf-8") as lines:
                for number, line in enumerate(lines, 1):
                    code, block = strip_code(line, block)
                    # A name of Odin's runtime is not this tree's vocabulary.
                    hit = FORMAT_WORD.search(re.sub(r"runtime\.\w+", "", code.lower()))
                    if hit:
                        print(f"{path}:{number}: {hit.group(1)}")
                        found += 1
    return 1 if found else 0


def surface():
    for package in PACKAGES:
        names = set()
        for path in package_files(package):
            names.update(declarations(path))
        print(f"# {package}")
        for name in sorted(names):
            print(name)
        print()
    return 0


def main(argv):
    commands = {"size": size, "imports": imports, "surface": surface, "words": words}
    if len(argv) != 2 or argv[1] not in commands:
        print("usage: checks.py size|imports|surface|words", file=sys.stderr)
        return 2
    return commands[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
