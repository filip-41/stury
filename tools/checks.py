#!/usr/bin/env python3
"""Checks over the tree: its import order, its public surface, and the words in core.

Run from the repository root: `python3 tools/checks.py imports`, `surface` or `words`.
"""

import os
import subprocess
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def makefile_list(name):
    """The words of the Makefile's `name := ...` line, the one place the package lists are kept."""
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as file:
        for line in file:
            head = line.split(":=", 1)
            if len(head) == 2 and head[0].strip() == name:
                return head[1].split()
    raise ValueError(f"Makefile has no {name}")


# The library packages, and the order imports of them take. json and dsv share the last rank.
PACKAGES = makefile_list("LIB_PKGS")
RANK = {"core/spell": 0, "core": 1, "host": 2, "core/kernel": 2, "core/compose": 2, "core/build": 3, "core/typed": 4, "core/write": 5, "core/records": 6, "json": 7, "dsv": 7}
FORMATS = {"json", "dsv"}

# core's format-neutral packages name no format's concept in their code. core/kernel is left out: its tables are a byte
# shuffle's.
NEUTRAL = ["core/spell", "core", "core/compose", "core/build", "core/typed", "core/write", "core/records"]
FORMAT_WORD = re.compile(r"(?<![a-z])(header|table|cell|delimiter)s?(?![a-z])")
# The words a neutral package may use, since its users look for them: `records.cell` and `records.write_cells`.
ALLOWED_WORDS = {"core/records": {"cell"}}

DECL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(::|:=|:)")


def odin_files():
    """Every tracked .odin file, in path order: a checkout may hold local work beside the tree."""
    out = subprocess.run(["git", "ls-files", "*.odin"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [os.path.join(ROOT, name) for name in out.split()]


def package_files(package):
    """The .odin files directly in a package directory, never a subpackage's."""
    directory = os.path.join(ROOT, package)
    return [
        os.path.join(directory, name)
        for name in sorted(os.listdir(directory))
        if name.endswith(".odin")
    ]


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
    """Returns the package a relative import names, as a path under the root, or None for a collection import."""
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
    for source in odin_files():
        here = importer_package(source)
        last = -1
        for path in imports_in(source):
            target = resolve(path, source)
            if target == "<outside>":
                errors.append(f"{os.path.relpath(source, ROOT)}: imports {path!r} outside the root")
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
    """Yields the public top-level names of a file with the first line of each declaration."""
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
                    yield name, re.sub(r"\s+", " ", stripped)
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
                    if hit and hit.group(1) not in ALLOWED_WORDS.get(package, ()):
                        print(f"{path}:{number}: {hit.group(1)}")
                        found += 1
    return 1 if found else 0


def surface():
    for package in PACKAGES:
        names = set()
        for path in package_files(package):
            names.update(name for name, _ in declarations(path))
        print(f"# {package}")
        for name in sorted(names):
            print(name)
        print()
    return 0


API_FILE = os.path.join(ROOT, "API.txt")


def signatures():
    """One line per public top-level name of each library package: its declaration's first line."""
    lines = ["generated by `python3 tools/checks.py api --write`, do not edit"]
    for package in PACKAGES:
        found = {}
        for path in package_files(package):
            found.update(declarations(path))
        lines.append(f"# {package}")
        lines += [found[name] for name in sorted(found)]
    return "\n".join(lines) + "\n"


def api(write=False):
    """Compares the public signatures with API.txt. A change of the surface regenerates it with `--write`."""
    now = signatures()
    if write:
        with open(API_FILE, "w", encoding="utf-8") as file:
            file.write(now)
        return 0
    try:
        with open(API_FILE, encoding="utf-8") as file:
            before = file.read()
    except FileNotFoundError:
        before = ""
    if before == now:
        return 0
    old, new = set(before.splitlines()), set(now.splitlines())
    for line in sorted(old - new):
        print(f"- {line}")
    for line in sorted(new - old):
        print(f"+ {line}")
    print("API.txt differs: regenerate it with `python3 tools/checks.py api --write` and review the change")
    return 1


# A file-scope variable is `name := v`, `name: T` or `name: T = v`. `@(rodata)` and `@(thread_local)` make one safe.
VARIABLE = re.compile(r"^([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:(?!:)")
LEADING_ATTRIBUTE = re.compile(r"@\(([^)]*)\)\s*")
SAFE_ATTRIBUTES = {"rodata", "thread_local"}
# A format's `SPELLING` points at its other tables, and `@(rodata)` refuses an address in its initializer. It is set once
# by the compiler's static initialization and no code writes it.
POINTING_TABLES = {"json/document.odin": "SPELLING", "dsv/document.odin": "SPELLING"}


def is_variable(rest):
    """`rest` follows the first colon of a declaration: `= v`, `T = v` and `T` are variables, `: v` and `T : v` constants."""
    if rest.startswith(":"):
        return False
    depth = 0
    for c in rest:
        depth += c in "([{"
        depth -= c in ")]}"
        if depth == 0 and c in ":=":
            return c == "="
    return True


def globals_check():
    """Names every mutable package-level variable of the library, which every thread that runs a scan would share."""
    found = 0
    for package in PACKAGES:
        for path in package_files(package):
            found += mutable_globals(path)
    return 1 if found else 0


def mutable_globals(path):
    found = 0
    open_brackets = []
    attributes = set()
    block = False
    with open(path, encoding="utf-8") as file:
        for number, line in enumerate(file, 1):
            code, block = strip_code(line, block)
            text = code.strip()
            top = all(open_brackets)
            while top and (attr := LEADING_ATTRIBUTE.match(text)):
                attributes |= {part.split("=")[0].strip() for part in attr.group(1).split(",")}
                text = text[attr.end():]
            named = VARIABLE.match(text) if top else None
            where = os.path.relpath(path, ROOT)
            if named and not attributes & SAFE_ATTRIBUTES and is_variable(text[named.end():].strip()) and POINTING_TABLES.get(where) != named.group(1):
                print(f"{where}:{number}: {named.group(1)}")
                found += 1
            if text:
                attributes = set()
            when = re.match(r"^(when|else|foreign)\b", text) is not None
            for c in code:
                if c in "({[":
                    open_brackets.append(c == "{" and when and top)
                elif c in ")}]" and open_brackets:
                    open_brackets.pop()
    return found


def main(argv):
    commands = {"imports": imports, "surface": surface, "words": words, "globals": globals_check, "api": api}
    if len(argv) < 2 or argv[1] not in commands or argv[2:] not in ([], ["--write"]) or argv[2:] and argv[1] != "api":
        print("usage: checks.py imports|surface|words|globals|api [--write]", file=sys.stderr)
        return 2
    if argv[1] == "api":
        return api(write=bool(argv[2:]))
    return commands[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
