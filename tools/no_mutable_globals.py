#!/usr/bin/env python3
"""No mutable package-level state in the library packages.

WHAT THIS IS. The batch-parallel driver runs scans on many threads. That is only
safe when no library package under `core/`, `csv/`, `host/` or `json/` holds a
package-level variable: a global written by one scan is read by the next, on
another thread.
This finds every file-scope variable declaration there and exits non-zero naming
each one. It needs no Odin toolchain and reads source text, so a release archive
runs it (`make lint`) exactly as a checkout does.

WHAT COUNTS. At file scope, `name := v`, `name: T` and `name: T = v` are mutable
variables (flagged). `name :: v` and the typed constant `name: T : v` are
compile-time constants (allowed). A declaration under `@(rodata)` is immutable
(allowed), alone or among several attributes (`@(private, rodata)`). One under
`@(thread_local)` is per thread, so no other thread's scan reads it (allowed):
what it holds must be a cache, never a result one scan hands the next. Anything in
a `when` or `foreign` block is still package level, so those braces are looked
through; the bodies of procs, structs, enums and literals are not, and neither
are a proc signature's parameters.

HOW. Odin has no cheap parser here, so this is a small scanner: comments and
string/rune literals are blanked first (a `:=` inside either is not a
declaration), then brackets are counted char by char, because indentation does not show it
and brace depth alone does not see `proc(\\n  s: ^Scanner,\\n)`. A statement ends
at a newline while file scope is open.

WHICH PACKAGES. Every `.odin` file under `core/`, `csv/`, `host/` and `json/` except those below a
directory named `test`, found by walking the tree and not by reading the
Makefile's LIB_PKGS. The Makefile list is a hand-kept registry: a package added
and forgotten there would be silently exempt, which is the failure this guards
against. `json/test/stock` is in LIB_PKGS but is the differential test harness,
not shipped library code, so it is out of scope by its path.

Exit codes:
  0  no mutable package-level variable in any library package
  1  one or more, each named as path:line: names (form)
  2  harness error: nothing was scanned, so nothing was cleared
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG_ROOTS = ("core", "csv", "host", "json")
SKIP_DIR = "test"

NAMES = r"[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*"
DECL = re.compile(r"(%s)\s*:" % NAMES)
ATTR = re.compile(r"@\s*(?:\(|(\w+))")
# A block opened by one of these heads keeps its contents at package level.
TRANSPARENT_HEAD = re.compile(r"(?:when|else|foreign)\b")


def blank(src):
    """`src` with comment text and string/rune/raw-string contents replaced by
    spaces. Length and newlines are kept so offsets still give line numbers."""
    out, i, n = list(src), 0, len(src)

    def wipe(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            wipe(i, j)
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif src.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            wipe(i, j)
            i = j
        elif src[i] in "\"'":
            q, j = src[i], i + 1
            while j < n and src[j] != q and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            wipe(i + 1, j)
            i = j + 1
        elif src[i] == "`":
            j = src.find("`", i + 1)
            j = n if j < 0 else j
            wipe(i + 1, j)
            i = j + 1
        else:
            i += 1
    return "".join(out)


def matching(s, i):
    """Index just past the bracket that closes the one opening at s[i]."""
    depth = 0
    for j in range(i, len(s)):
        depth += s[j] in "([{"
        depth -= s[j] in ")]}"
        if depth == 0:
            return j + 1
    return len(s)


def strip_attrs(stmt):
    """(attribute names, rest). `@(private, rodata = x) foo` -> ({private, rodata}, foo)."""
    names = set()
    stmt = stmt.lstrip()
    while True:
        m = ATTR.match(stmt)
        if not m:
            return names, stmt
        if m.group(1):
            names.add(m.group(1))
            stmt = stmt[m.end():].lstrip()
            continue
        end = matching(stmt, m.end() - 1)
        for part in split_top(stmt[m.end():end - 1]):
            names.add(part.split("=")[0].strip())
        stmt = stmt[end:].lstrip()


def split_top(s):
    parts, depth, cur = [], 0, []
    for ch in s:
        depth += ch in "([{"
        depth -= ch in ")]}"
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


def variable_form(rest):
    """`rest` is what follows `names :`. The flagged form (`:=`, `: T`, `: T = v`),
    or None for `:: v` and the typed constant `T : v`."""
    if rest.startswith(":"):
        return None
    if rest.startswith("="):
        return ":="
    depth = 0
    for ch in rest:
        depth += ch in "([{"
        depth -= ch in ")]}"
        if depth == 0 and ch in ":=":
            return ": T = v" if ch == "=" else None
    return ": T"


def classify(stmt, pending):
    """(names, form) when `stmt` is a flagged variable declaration, else None.
    `pending` is the attribute set carried from an attribute-only line above."""
    attrs, rest = strip_attrs(stmt)
    if not rest:
        pending |= attrs
        return None
    attrs |= pending
    pending.clear()
    m = DECL.match(rest)
    if not m or "rodata" in attrs or "thread_local" in attrs:
        return None
    form = variable_form(rest[m.end():])
    return (m.group(1), form) if form else None


def find_globals(src):
    """[(line, names, form)] for every file-scope variable in Odin source `src`."""
    text = blank(src)
    stack = []  # one entry per open bracket: True for a transparent `{`
    start = None
    pending, hits = set(), []

    def at_file_scope():
        return all(stack)

    def end_statement(end):
        nonlocal start
        if start is not None:
            found = classify(text[start:end], pending)
            if found:
                s = text[start:end].lstrip()
                skip = len(text[start:end]) - len(s)
                # the declaration's own line, not an attribute line above it
                rest = strip_attrs(s)[1]
                at = start + skip + (len(s) - len(rest))
                hits.append((text.count("\n", 0, at) + 1,) + found)
        start = None

    for i, ch in enumerate(text):
        if ch in ")]}":
            popped = stack.pop() if stack else False
            if ch == "}" and popped:
                start = None
            continue
        if ch in "\n;" and at_file_scope():
            end_statement(i)
            continue
        if start is None and not ch.isspace() and at_file_scope():
            start = i
        if ch == "{":
            head = text[start:i].lstrip() if start is not None else ""
            stack.append(at_file_scope() and bool(TRANSPARENT_HEAD.match(head)))
            if stack[-1]:
                start = None  # the `when X {` line is not a declaration
        elif ch in "([":
            stack.append(False)
    end_statement(len(text))
    return hits


def library_files(root):
    for pkg in PKG_ROOTS:
        for dirpath, dirs, files in os.walk(os.path.join(root, pkg)):
            dirs[:] = sorted(d for d in dirs if d != SKIP_DIR)
            for f in sorted(files):
                if f.endswith(".odin"):
                    yield os.path.join(dirpath, f)


def scan_tree(root):
    """(files scanned, [(relpath, line, names, form)])."""
    count, found = 0, []
    for path in library_files(root):
        count += 1
        with open(path, encoding="utf-8") as f:
            src = f.read()
        rel = os.path.relpath(path, root)
        found += [(rel,) + h for h in find_globals(src)]
    return count, found


def main(argv):
    root = argv[0] if argv else ROOT
    count, found = scan_tree(root)
    if count == 0:
        print("NO-FILES no .odin file under %s of %s: nothing was checked"
              % (" or ".join(p + "/" for p in PKG_ROOTS), root))
        return 2
    for rel, line, names, form in found:
        print("%s:%d: %s (%s)" % (rel, line, names, form))
    if found:
        print("MUTABLE PACKAGE-LEVEL STATE: %d declaration(s) in %d file(s) scanned"
              % (len(found), count))
        return 1
    print("no mutable package-level state in %d library file(s)" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
