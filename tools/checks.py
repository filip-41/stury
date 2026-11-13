#!/usr/bin/env python3
"""Checks over the tree: its import order, its public surface, and the words in core.

Run from the repository root: `python3 tools/checks.py imports|surface|words|globals|api [--write]`. `odin PATH` checks
the compiler against the Makefile's MIN_ODIN and `list NAME` prints a Makefile list, one word per line.

`api` keeps two files. API.txt is the user surface. API_SHARED.txt holds the public names that only stury's own packages
use. A name is shared when another library package or cmd/ calls it as `package.name`, README.md, docs/guide.md and
examples/ never mention it, and no user-surface declaration names it in its signature or fields. Tests, walktest/ and
bench/ are not callers. A name that nothing outside its package calls stays in the user surface.
"""

import os
import subprocess
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def makefile_list(name):
    """The words of the Makefile's `name := ...` (or `?=`) line, the one place the package lists are kept."""
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as file:
        for line in file:
            found = re.match(rf"{name}\s*[:?]?=\s*(.*)", line)
            if found:
                return found.group(1).split()
    raise ValueError(f"Makefile has no {name}")


MIN_ODIN = makefile_list("MIN_ODIN")[0]
RELEASE = re.compile(r"dev-(\d+)-(\d+)([a-z]?)")


def odin_problem(odin):
    """Why `odin` cannot build this tree, or None. The oldest release that passes `make lint` is MIN_ODIN."""
    try:
        said = subprocess.run([odin, "version"], capture_output=True, text=True).stdout
    except OSError as error:
        return f"ODIN={odin} cannot run ({error.strerror}): pass ODIN=<path to odin>, release {MIN_ODIN} or later"
    found = RELEASE.search(said)
    if not found:
        return f"ODIN={odin} names no release in `odin version`: stury needs Odin {MIN_ODIN} or later"
    if found.groups() < RELEASE.fullmatch(MIN_ODIN).groups():
        return f"{odin} is {found.group(0)}: stury needs Odin {MIN_ODIN} or later"
    return None


# The library packages, and the order imports of them take. json and dsv share a rank, under core/model.
PACKAGES = makefile_list("LIB_PKGS")
RANK = {"core/spell": 0, "core/regex": 0, "core": 1, "host": 2, "core/kernel": 2, "core/compose": 2, "core/diff": 2, "core/rules": 2, "core/css": 2, "core/build": 3, "core/typed": 4, "core/write": 5, "core/records": 6, "core/schema": 7, "json": 8, "dsv": 8, "core/model": 9, "toml": 8, "xml": 8, "yaml": 8, "cbor": 8, "html": 8}
FORMATS = {"json", "dsv", "toml", "xml", "yaml", "cbor", "html"}

# core's format-neutral packages name no format's concept in their code. core/kernel is left out: its tables are a byte
# shuffle's.
NEUTRAL = ["core/spell", "core", "core/compose", "core/css", "core/diff", "core/rules", "core/build", "core/typed", "core/write", "core/records", "core/schema", "core/model"]
FORMAT_WORD = re.compile(r"(?<![a-z])(header|table|cell|delimiter)s?(?![a-z])")
# The words a neutral package may use, since its users look for them: `records.cell` and `records.write_cells`, and the
# document's `Table`, whose rows share a header.
TABLE_WORDS = {"table", "header"}
ALLOWED_WORDS = {"core/records": {"cell"}, "core": TABLE_WORDS, "core/build": TABLE_WORDS, "core/compose": TABLE_WORDS, "core/typed": TABLE_WORDS}

DECL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(::|:=|:)")


def odin_files():
    """Every .odin file in path order: the tracked and the untracked ones that git does not ignore, or, outside a git
    checkout, every one on disk."""
    try:
        out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.odin"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        return [os.path.join(ROOT, name) for name in sorted(set(out.split()))]
    except (OSError, subprocess.CalledProcessError):
        found = []
        for base, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in sorted(dirs) if d != "build" and not d.startswith(".")]
            found += [os.path.join(base, name) for name in sorted(files) if name.endswith(".odin")]
        return found


def package_files(package):
    """The .odin files directly in a package directory, never a subpackage's."""
    directory = os.path.join(ROOT, package)
    return [
        os.path.join(directory, name)
        for name in sorted(os.listdir(directory))
        if name.endswith(".odin")
    ]


def strip_code(line, block, keep_strings=False):
    """Returns the line outside comments, and outside strings unless `keep_strings`, and whether a block comment is open."""
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
            quote, start = c, i
            i += 1
            while i < len(line):
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == quote:
                    i += 1
                    break
                i += 1
            if keep_strings:
                out.append(line[start:i])
            continue
        out.append(c)
        i += 1
    return "".join(out), block


IMPORT = re.compile(r'^\s*import\s+(?:([A-Za-z_][A-Za-z0-9_]*)\s+)?"([^"]+)"\s*$')
IMPORT_GROUP = re.compile(r"^\s*import\s*\(\s*$")
GROUPED = re.compile(r'^\s*(?:([A-Za-z_][A-Za-z0-9_]*)\s+)?"([^"]+)"\s*,?\s*$')


def imports_in(path):
    """Yields the (alias or None, import path) of each import of a file, in file order."""
    grouped = False
    with open(path, encoding="utf-8") as file:
        for line in file:
            if grouped:
                if line.strip() == ")":
                    grouped = False
                    continue
                found = GROUPED.match(line)
                if found:
                    yield found.groups()
                continue
            if IMPORT_GROUP.match(line):
                grouped = True
                continue
            found = IMPORT.match(line)
            if found:
                yield found.groups()


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
        for _, path in imports_in(source):
            target = resolve(path, source)
            if target == "<outside>":
                errors.append(f"imports: {os.path.relpath(source, ROOT)}: imports {path!r} outside the root")
                continue
            if target is None:
                continue
            tag = os.path.relpath(source, ROOT)
            rank = RANK.get(target)
            if rank is not None:
                if rank < last:
                    errors.append(f"imports: {tag}: imports {target!r} out of order")
                last = max(last, rank)
                here_rank = RANK.get(here)
                if here_rank is not None and rank >= here_rank:
                    errors.append(f"imports: {tag}: imports {target!r}, which does not rank below {here!r}")
                if here in FORMATS and target in FORMATS and here != target:
                    errors.append(f"imports: {tag}: {here} imports {target}, and formats do not import each other")
    for line in errors:
        print(line)
    return 1 if errors else 0


ATTR = re.compile(r"^\s*@\((.*)\)\s*$")


# A procedure with a body. A `#type proc` and a group `proc {a, b}` have none.
PROC = re.compile(r"^(#(?!type\b)\w+\s+)*proc\b(?!\s*\{)")
# A declaration whose whole text is surface: a type with its fields or members, and a procedure group.
WHOLE = re.compile(r"^(distinct\s+)?(struct|enum|union|bit_field|proc\s*\{)")


def shape_of(rest):
    """How much of a declaration whose text after the name's `::` is `rest` is surface."""
    if PROC.match(rest):
        return "signature"
    return "whole" if WHOLE.match(rest) else "line"


def body_start(signature):
    """The index of a procedure's body, `{` or `---` outside brackets and strings, or -1 while the signature goes on."""
    depth = 0
    i = 0
    while i < len(signature):
        c = signature[i]
        if c in "\"'":
            end = i + 1
            while end < len(signature) and signature[end] != c:
                end += 2 if signature[end] == "\\" else 1
            i = end + 1
            continue
        if depth == 0 and (c == "{" or signature.startswith("---", i)):
            return i
        depth += c in "(["
        depth -= c in ")]"
        i += 1
    return -1


def declarations(path):
    """Yields the public top-level names of a file with each declaration's surface: a procedure's signature up to its
    body, a type's or a group's whole text, and the first line of a constant or a variable."""
    # Each open brace is True for a `when` block, which holds top-level declarations.
    open_braces = []
    pending_private = False
    block = False
    current = None
    with open(path, encoding="utf-8") as file:
        # A `#+private` file tag before the package clause makes every declaration of the file private.
        if re.search(r"^#\+private\b", file.read().split("\npackage ", 1)[0], re.M):
            return
        file.seek(0)
        for line in file:
            text, _ = strip_code(line, block, keep_strings=True)
            code, block = strip_code(line, block)
            stripped = code.strip()
            attr = ATTR.match(code)
            if attr and not open_braces and current is None:
                attributes = {part.strip() for part in attr.group(1).split(",")}
                if any(a == "private" or a.startswith("private ") for a in attributes):
                    pending_private = True
                continue
            top = all(open_braces)
            found = DECL.match(code) if top and current is None else None
            if found:
                name = found.group(1)
                if not pending_private and not name.startswith("_"):
                    current = (name, shape_of(text[found.end():].strip()), len(open_braces), [], [])
                pending_private = False
            elif stripped and not stripped.startswith("@"):
                pending_private = False
            # A block built only for tests (`when ODIN_TEST ...`) holds no surface.
            when = re.match(r"^(when|else)\b", stripped) is not None and "ODIN_TEST" not in stripped
            for c in code:
                if c == "{":
                    open_braces.append(when and all(open_braces))
                elif c == "}":
                    if open_braces:
                        open_braces.pop()
            if current is not None:
                name, shape, depth, parts, codes = current
                parts.append(text.strip())
                codes.append(code)
                whole = re.sub(r"\s+", " ", " ".join(parts)).strip()
                if shape == "signature":
                    at = whole.index("proc", whole.index(":"))
                    end = body_start(whole[at:])
                    if end >= 0:
                        current = None
                        yield name, whole[: at + end].rstrip()
                elif shape == "line" or len(open_braces) <= depth and "".join(codes).count("(") == "".join(codes).count(")"):
                    current = None
                    yield name, whole
    if open_braces or current is not None:
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
                        print(f"words: {os.path.relpath(path, ROOT)}:{number}: {hit.group(1)!r} names a format's concept in a neutral package")
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
SHARED_FILE = os.path.join(ROOT, "API_SHARED.txt")
HEADER = "generated by `python3 tools/checks.py api --write`, do not edit"

# The user surface is every public name of a library package except the shared ones. A name is shared when another
# library package or cmd/ calls it as `package.name`, README.md, docs/guide.md and examples/ never mention it, and no
# user-surface declaration names it in its signature or fields. Tests, walktest/ and bench/ are not callers.
DOC_FILES = ["README.md", "docs/guide.md"]
NOT_CALLERS = {"walktest", "bench", "tools"}


def source_kind(path):
    """Whether a file is `test`, `example` or `own` code, own being the library packages and cmd/."""
    parts = os.path.relpath(path, ROOT).split(os.sep)
    if parts[0] == "examples":
        return "example"
    return "test" if "test" in parts[:-1] or parts[0] in NOT_CALLERS else "own"


def qualified_calls(path):
    """Yields (package, name) for each `alias.name` that a file reads from a library package. An alias is the name an
    import gives, or the last element of its path."""
    aliases = {}
    for alias, imported in imports_in(path):
        collection = re.match(r"^[A-Za-z_][A-Za-z0-9_]*:(.*)", imported)
        target = collection.group(1) if collection else resolve(imported, path)
        if target in PACKAGES:
            aliases[alias or target.rsplit("/", 1)[-1]] = target
    code, block = [], False
    with open(path, encoding="utf-8") as file:
        for line in file:
            text, block = strip_code(line, block)
            code.append(text)
    for alias, name in re.findall(r"(?<![\w.])([A-Za-z_]\w*)\.([A-Za-z_]\w*)", "".join(code)):
        if alias in aliases:
            yield aliases[alias], name


def shared_names(found):
    """The set of (package, name) that only stury's own packages use."""
    callers, documented = set(), ""
    for path in odin_files():
        kind = source_kind(path)
        if kind == "own":
            here = importer_package(path)
            callers.update((package, name) for package, name in qualified_calls(path) if package != here)
        elif kind == "example":
            with open(path, encoding="utf-8") as file:
                documented += file.read()
    for name in DOC_FILES:
        with open(os.path.join(ROOT, name), encoding="utf-8") as file:
            documented += file.read()
    words = set(re.findall(r"[A-Za-z_]\w*", documented))
    shared = {(package, name) for package, name in callers if name not in words and name in found[package]}
    # A user reads the types in the declarations it calls, so a shared name a user declaration mentions is not shared.
    by_alias = {package.rsplit("/", 1)[-1]: package for package in PACKAGES}
    pending = [(package, line) for package in PACKAGES for name, line in found[package].items() if (package, name) not in shared]
    while pending:
        package, line = pending.pop()
        mentioned = {(package, name) for name in re.findall(r"(?<![\w.])[A-Za-z_]\w*", line)}
        mentioned |= {(by_alias[alias], name) for alias, name in re.findall(r"(?<![\w.])([A-Za-z_]\w*)\.([A-Za-z_]\w*)", line) if alias in by_alias}
        for name in mentioned & shared:
            shared.discard(name)
            pending.append((name[0], found[name[0]][name[1]]))
    return shared


NAMES_LIST = os.path.join(ROOT, "tools", "names.txt")
NAMES_HEADER = "// generated by `python3 tools/checks.py api --write`, do not edit"


def names_read():
    """The exports of tools/names.txt as (package, name, alias), the members of the `destroy` group as (package, name),
    and the formats a line's head limits its names to, keyed by its package or by its destroy member."""
    exports, destroy, only = [], [], {}
    with open(NAMES_LIST, encoding="utf-8") as file:
        for line in file:
            if line.startswith("#") or not line.strip():
                continue
            head, listed = line.split(":", 1)
            head, _, formats = head.partition(" [")
            if head == "destroy":
                members = [tuple(word.split(".")) for word in listed.split()]
                destroy += members
                only.update({member: set(formats.rstrip("]").split()) for member in members if formats})
            else:
                if formats:
                    only[head] = set(formats.rstrip("]").split())
                for word in listed.split():
                    name, _, alias = word.partition("=")
                    exports.append((head, name, alias or name))
    return exports, destroy, only


def package_name(package):
    return package.rsplit("/", 1)[-1]


def declared(package, skip_names=False):
    """The public names a package declares, without its generated names file when `skip_names`."""
    names = set()
    for path in package_files(package):
        if not (skip_names and os.path.basename(path) == "names.odin"):
            names.update(name for name, _ in declarations(path))
            if skip_names:
                # A private name shadows an alias in its file, so a format does not export a name any of its files declares.
                with open(path, encoding="utf-8") as file:
                    names.update(re.findall(r"^([A-Za-z_]\w*)\s*::", file.read(), re.M))
    return names


def names_files():
    """The text of each format package's names.odin, and the problems with the list. A format exports every listed name
    except those it declares itself."""
    exports, destroy, only = names_read()
    by_name = {package_name(package): package for package, _, _ in exports}
    by_name.update({package_name(package): package for package in PACKAGES})
    found = {package: declared(package) for package in {package for package, _, _ in exports}}
    problems = [f"names: {package} declares no {name}" for package, name, _ in exports if name not in found[package]]
    for owner, name in destroy:
        if owner in FORMATS:
            if name not in declared(owner, skip_names=True):
                problems.append(f"names: {owner} declares no {name}")
        elif owner not in by_name or name not in declared(by_name[owner]):
            problems.append(f"names: {owner}.{name} is not a public name")
    shared = [(owner, name) for owner, name in destroy if owner not in FORMATS]
    files = {}
    for fmt in sorted(FORMATS):
        own = declared(fmt, skip_names=True)
        taken, lines = {}, []
        for package, name, alias in exports:
            if alias in own or name not in found[package] or fmt not in only.get(package, {fmt}):
                continue
            if alias in taken:
                problems.append(f"names: {fmt}: {alias} is exported from {taken[alias]} and from {package}")
            taken[alias] = package
            lines.append((package, f"{alias} :: {package_name(package)}.{name}"))
        # A format's own member, which may be private to it, joins only its own group, by its bare name.
        reached = [(owner, name) for owner, name in shared if fmt in only.get((owner, name), {fmt})]
        members = [f"{owner}.{name}" for owner, name in reached] + [name for owner, name in destroy if owner == fmt] if "destroy" not in own else []
        used = {package for package, _ in lines} | {by_name[owner] for owner, _ in reached if members}
        text = [NAMES_HEADER, f"package {fmt}", ""]
        text += [f'import {package_name(package)} "../{package}"' for package in sorted(used, key=PACKAGES.index)]
        text.append("")
        for package in sorted({package for package, _ in lines}, key=PACKAGES.index):
            text += [line for owner, line in lines if owner == package] + [""]
        if members:
            text.append("destroy :: proc {" + ", ".join(members) + "}")
        files[os.path.join(ROOT, fmt, "names.odin")] = "\n".join(text).rstrip("\n") + "\n"
    return files, problems


def signatures():
    """The public top-level names of each library package, keyed by package: name to its declaration's first line."""
    return {package: dict(pair for path in package_files(package) for pair in declarations(path)) for package in PACKAGES}


def split_surface():
    """The API lines by package of the user surface and of the shared names. A name that tools/names.txt exports is
    a format package's own name there, so the package it comes from keeps only the format author's names."""
    found = signatures()
    exported = {(package, name) for package, name, _ in names_read()[0]}
    shared = shared_names(found) - exported
    user = {p: [found[p][n] for n in sorted(found[p]) if (p, n) not in shared | exported] for p in PACKAGES}
    inside = {p: [found[p][n] for n in sorted(found[p]) if (p, n) in shared] for p in PACKAGES}
    return user, {p: lines for p, lines in inside.items() if lines}


USER_PACKAGES = FORMATS | {"core/model"}
AUTHOR_DIVIDER = "## Format author names"


def api_text(by_package, divider=False):
    """An API file: the user packages, then with `divider` a line and the packages a format author reads."""
    order = sorted(by_package, key=lambda p: (p not in USER_PACKAGES, PACKAGES.index(p))) if divider else list(by_package)
    out = [HEADER]
    for package in order:
        if divider and package not in USER_PACKAGES and AUTHOR_DIVIDER not in out:
            out.append(AUTHOR_DIVIDER)
        out += [f"# {package}"] + by_package[package]
    return "\n".join(out) + "\n"


def api_read(path):
    """An API file's lines by package, empty when the file is missing."""
    out, package = {}, None
    try:
        with open(path, encoding="utf-8") as file:
            lines = file.read().splitlines()[1:]
    except FileNotFoundError:
        return out
    for line in lines:
        if line == AUTHOR_DIVIDER:
            continue
        if line.startswith("# ") and line[2:] in PACKAGES:
            package = line[2:]
            out[package] = []
        elif package:
            out[package].append(line)
    return out


def api(write=False):
    """Compares the public signatures with API.txt and API_SHARED.txt, and the format packages' names files with
    tools/names.txt. A change of the surface regenerates them with `--write`."""
    files, problems = names_files()
    for problem in problems:
        print(problem)
    if problems:
        return 1
    if write:
        for path, text in files.items():
            with open(path, "w", encoding="utf-8") as file:
                file.write(text)
        for path, by_package in zip((API_FILE, SHARED_FILE), split_surface()):
            with open(path, "w", encoding="utf-8") as file:
                file.write(api_text(by_package, divider=path == API_FILE))
        print("wrote API.txt, API_SHARED.txt and the names files")
        return 0
    differs = False
    for path, text in files.items():
        if not os.path.exists(path) or open(path, encoding="utf-8").read() != text:
            print(f"api: {os.path.relpath(path, ROOT)} differs from tools/names.txt")
            differs = True
    for path, by_package in zip((API_FILE, SHARED_FILE), split_surface()):
        before = api_read(path)
        for package in PACKAGES:
            lines = by_package.get(package, [])
            old, new = before.get(package, []), set(lines)
            for line in [l for l in old if l not in new] + [l for l in lines if l not in old]:
                print(f"api: {os.path.basename(path)}: {package}: {'-' if line in old else '+'} {line}")
                differs = True
    if differs:
        print("api: API.txt, API_SHARED.txt or a names file differs from the sources: regenerate them with `make api-write` and review the change")
    return 1 if differs else 0


# A variable is `name := v`, `name: T` or `name: T = v`, at file scope or under `@(static)` in a procedure. Only
# `@(rodata)` makes one safe: a `@(thread_local)` one is state a thread carries from one scan to the next.
VARIABLE = re.compile(r"^([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:(?!:)")
LEADING_ATTRIBUTE = re.compile(r"@(?:\(([^)]*)\)|([A-Za-z_]\w*))\s*")
SAFE_ATTRIBUTES = {"rodata"}
# A format's `HANDLE` and `SERVICES` point at its other tables, and `@(rodata)` refuses an address in its initializer. It is set once
# by the compiler's static initialization and no code writes it.
POINTING_TABLES = {"json/document.odin": {"HANDLES", "SERVICES"}, "dsv/document.odin": {"HANDLES", "SERVICES"}, "toml/document.odin": {"HANDLES", "SERVICES"}, "xml/document.odin": {"HANDLES", "SERVICES"}, "yaml/document.odin": {"HANDLES", "SERVICES"}, "cbor/document.odin": {"HANDLE", "SERVICES"}, "html/document.odin": {"HANDLES", "SERVICES"}}


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
    """Names every mutable package-level or static variable of the library, which the scans that run would share."""
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
            while attr := LEADING_ATTRIBUTE.match(text):
                attributes |= {part.split("=")[0].strip() for part in (attr.group(1) or attr.group(2)).split(",")}
                text = text[attr.end():]
            named = VARIABLE.match(text) if top or "static" in attributes else None
            where = os.path.relpath(path, ROOT)
            if named and not attributes & SAFE_ATTRIBUTES and is_variable(text[named.end():].strip()) and named.group(1) not in POINTING_TABLES.get(where, ()):
                print(f"globals: {where}:{number}: {named.group(1)} is mutable package state, mark it @(rodata) or remove it")
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


def odin_check(odin):
    problem = odin_problem(odin)
    if problem:
        print(problem)
    return 1 if problem else 0


def main(argv):
    commands = {"imports": imports, "surface": surface, "words": words, "globals": globals_check, "api": api}
    if argv[1:2] == ["odin"] and len(argv) == 3:
        return odin_check(argv[2])
    if argv[1:2] == ["list"] and len(argv) == 3:
        print(*makefile_list(argv[2]), sep="\n")
        return 0
    if len(argv) < 2 or argv[1] not in commands or argv[2:] not in ([], ["--write"]) or argv[2:] and argv[1] != "api":
        print("usage: checks.py imports|surface|words|globals|api [--write]|odin PATH|list NAME", file=sys.stderr)
        return 2
    if argv[1] == "api":
        return api(write=bool(argv[2:]))
    return commands[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
