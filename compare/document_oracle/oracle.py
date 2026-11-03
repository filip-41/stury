"""oracle.py OLD_DIR NEW_DIR: the two trees' written texts must be the same bytes.

The layouts are compact, pretty at 2 and 4 spaces, tab (the old tree's indent 0), `ascii` and `escape_html`, each through
a built document and through `format`. A text one tree refused must be refused by the other.

Accepted: a comment after the root's close on a line of its own, in pretty text (`directedc01` and `directedc02`). The
old tree writes it on the root's line, where it reads back as the root's inline comment. next/ keeps it on its own line,
where it reads back as the root's foot. `ascii` and `escape_html` text. The old tree keeps a string's source escapes and only escapes what the option
asks, so `\\u0041` stays. next/ spells a string again whenever an option is set and writes the shortest spelling. Such
a text counts when it holds the option's guarantee and reads as the same value as the same text written compact by
next/, and as the old text when that is JSON. (The old tree writes bytes of junk before `utf8.json`'s `ascii` text.)
"""
import json, os, re, sys

OPTION = {"ascii": lambda b: all(c < 0x80 for c in b), "html": lambda b: not any(c in b"<>&" for c in b)}


def strip_comments(b):
    """The text of a JSONC `b` without its comments and trailing commas, as JSON."""
    out, i, n = bytearray(), 0, len(b)
    while i < n:
        c = b[i : i + 1]
        if c == b'"':
            j = i + 1
            while b[j : j + 1] != b'"':
                j += 2 if b[j : j + 1] == b"\\" else 1
            out += b[i : j + 1]
            i = j + 1
        elif b[i : i + 2] == b"//":
            while i < n and b[i : i + 1] != b"\n":
                i += 1
        elif b[i : i + 2] == b"/*":
            i = b.index(b"*/", i + 2) + 2
        else:
            out += c
            i += 1
    return re.sub(rb",(\s*[\]}])", rb"\1", bytes(out))


def load(b, jsonc):
    return json.loads(strip_comments(b) if jsonc else b)


def respelled(name, old, new, new_dir):
    """Whether `new` is an accepted respelling of the layout `name` carries."""
    base, layout = name.split(".")[0], name.split(".")[1]
    if layout not in OPTION or not OPTION[layout](new):
        return False
    compact = open(os.path.join(new_dir, f"{base}.compact{'.format' if '.format.' in name else ''}.json"), "rb").read()
    jsonc = base.endswith("_jsonc")
    try:
        value = load(new, jsonc)
    except ValueError:
        return False
    if value != load(compact, jsonc):
        return False
    try:
        return load(old, jsonc) == value
    except ValueError:
        return True


def root_foot(name, old, new):
    """Whether `new` is `old` with the root's foot on a line of its own."""
    if name.split(".")[0] not in ("directedc01_jsonc", "directedc02_jsonc"):
        return False
    return re.sub(rb"([\]}0-9])\n(?=//)", rb"\1 ", new, count=1) == old


def main():
    old_dir, new_dir = sys.argv[1:3]
    old_names, new_names = sorted(os.listdir(old_dir)), sorted(os.listdir(new_dir))
    failed = 0
    if old_names != new_names:
        print("the arms wrote different files:", sorted(set(old_names) ^ set(new_names)))
        failed = 1
    same = accepted = total = 0
    for name in old_names:
        if name not in new_names:
            continue
        old = open(os.path.join(old_dir, name), "rb").read()
        new = open(os.path.join(new_dir, name), "rb").read()
        total += 1
        if old == new:
            same += 1
        elif root_foot(name, old, new) or respelled(name, old, new, new_dir):
            accepted += 1
        else:
            failed = 1
            at = next((k for k in range(min(len(old), len(new))) if old[k] != new[k]), min(len(old), len(new)))
            print(f"{name}: differs at {at}\n  old {old[max(0, at - 40):at + 40]!r}\n  new {new[max(0, at - 40):at + 40]!r}")
    print(f"{same} of {total} texts are the same bytes, {accepted} respelled by an option")
    sys.exit(failed)


if __name__ == "__main__":
    main()
