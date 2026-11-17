"""Random XML texts run through the oracle program (stury's reader) and pyexpat (expat), both reading namespaces.

Well-formed documents come from a seeded grammar (every construct, multi-byte names and text, and an internal subset with
parameter entities) and from the conformance cases, and are then broken a byte, a token or a cut at a time. A text is a
difference when one parser accepts it and the other refuses it, unless xmllint (libxml2, when installed) gives stury's
verdict, since expat's name characters are the 4th edition's. A disagreement on a refusal's offset alone is counted
apart. SKIP lists what stury differs in on purpose, and a text stury refuses with `entity_respelled` is left out.
"""

import glob
import os
import random
import re
import shutil
import struct
import subprocess
import warnings
import xml.parsers.expat

import pytest

from capped import ROOT

pytestmark = pytest.mark.xdist_group("xml")
DEFAULT_SEEDS = [1, 2, 3]
CASES = 40000

NAMES = ["a", "b", "item", "x1", "_u", "a-b", "a.b", "p:q", "é", "名前", "Ωmega", "n·m"]
# Declarations an element may carry, so the prefixes of NAMES resolve in most documents.
DECLARATIONS = ['', ' xmlns:p="urn:p"', ' xmlns="urn:d" xmlns:p="urn:p"', ' xmlns:p="urn:p" xmlns:q="urn:p"',
                " xmlns:xml='http://www.w3.org/XML/1998/namespace'", ' xmlns:p="urn:p" xmlns:é="urn:e"']
# A name with a supplementary-plane letter, which XML 1.0 5th edition allows and expat refuses, is left out.
TEXTS = ["hi", " ", "\n", "a b", "é中", "\U0001F600", "x]y", "]]", "a>b", "\t", "&amp;", "&lt;&gt;", "&#65;", "&#x1F600;",
         "&quot;&apos;", "<![CDATA[a<b]]>", "<![CDATA[]]>", "<!-- c -->", "<?pi data?>", "\r\n", "line\nline"]
TRICKY = [b"<", b">", b"&", b";", b"]]>", b"--", b"-->", b"<!--", b"<![CDATA[", b"?>", b"<?", b"\x00", b"\x01", b"\x1f",
          b"\xff", b"\xc0\x80", b"\xed\xa0\x80", b"\xef\xbf\xbe", b"\xef\xbf\xbf", b"\xf4\x90\x80\x80", b"&#0;",
          b"&#x110000;", b"&#xD800;", b"&#;", b"&#x;", b"&amp", b"&nbsp;", b"\r", b"\r\n", b"/", b"=", b"'", b'"',
          b" ", b"\t", b"<a>", b"</a>", b"</", b"<a/>", b"xml", b"<?xml version='1.0'?>", b"\xc2\x85",
          b"\xe2\x80\xa8", b":", b"<1", b"\xcc\x81"]
# U+FEFF and U+FFFD are left out of the pool: XML 1.0 5th edition has them as name characters, expat's tables are the 4th's.

# (why stury answers otherwise, a test of the text).
SKIP = [
    ("expat reads any version number, the grammar has 1. and digits",
     lambda t: t.startswith(b"<?xml version=") and not re.match(rb"<\?xml version=(\"1\.[0-9]+\"|'1\.[0-9]+')", t)),
    ("stury reads a namespace name with a reference to an entity it did not read as its text, expat skips the reference",
     lambda t: unread_in_namespace(t)),
    ("only UTF-8 is read until encodings are", lambda t: b"encoding" in t[:200] and b"<?xml" in t[:10]),
    ("a UTF-16 text is read once encodings are", lambda t: t[:2] in (b"\xff\xfe", b"\xfe\xff") or t[:1] == b"\x00"),
]


def unread_in_namespace(text):
    for value in re.findall(rb"xmlns(?::[^\s=]+)?\s*=\s*(?:\"([^\"]*)\"|'([^']*)')", text):
        for ref in re.findall(rb"&([^#;&\s][^;&\s]*);", b"".join(value)):
            if ref not in (b"amp", b"lt", b"gt", b"quot", b"apos") and not re.search(rb"<!ENTITY\s+" + re.escape(ref) + rb"\s", text):
                return True
    return False


def name(rng):
    return rng.choice(NAMES)


# The entities a document's subset declares: text that may stand in an attribute value, and text with markup.
TEXT_ENTITIES = ["t", "u", "é"]
MARKUP_ENTITIES = ["m", "n"]
ENTITY_TEXTS = ["text", "a &amp; b", "&#65;&#x42;", "é中", "", "x\ty", "&lt;b&gt;", "a\r\nb"]
MARKUP_TEXTS = ["<b>t</b>", "<b k='v'/>", "x<c>y</c>z", "<!-- c -->t", "<?p d?>", "<![CDATA[<]]>", "<b>&t;</b>"]
ATTRIBUTE_TYPES = ["CDATA", "NMTOKEN", "NMTOKENS", "ID", "IDREF", "(x|y)", "ENTITY", "NOTATION (n)"]
ATTRIBUTE_DEFAULTS = ["#IMPLIED", "#REQUIRED", "'v'", "#FIXED 'v'", "'  a  b  '", "\"x&#9;y\"", "'&t;'", "'p q'"]
DECLARATIONS_OF_ELEMENTS = ["EMPTY", "ANY", "(#PCDATA)", "(#PCDATA|b|c)*", "(b,c?)+", "(b|(c,a)*)"]


def subset(rng):
    """A DOCTYPE with an internal subset, and the entities a reference may name."""
    decls, text, markup = [], [], []
    for _ in range(rng.choice([1, 2, 3, 4, 6])):
        k = rng.randrange(8)
        if k == 0:
            n = rng.choice(TEXT_ENTITIES)
            value = rng.choice(ENTITY_TEXTS + [f"x &{e}; y" for e in text])
            q = rng.choice("\"'")
            decls.append(f"<!ENTITY {n} {q}{value.replace(q, '')}{q}>")
            text.append(n)
        elif k == 1:
            n = rng.choice(MARKUP_ENTITIES)
            body = rng.choice(MARKUP_TEXTS).replace("&t;", "&t;" if "t" in text else "")
            decls.append(f'<!ENTITY {n} "{body}">')
            markup.append(n)
        elif k == 2:
            decls.append(f"<!ATTLIST {name(rng)} {rng.choice(['k', 'z', 'p:k', 'xmlns:p'])} {rng.choice(ATTRIBUTE_TYPES)} "
                         f"{rng.choice(ATTRIBUTE_DEFAULTS).replace('&t;', '&t;' if 't' in text else 't')}>")
        elif k == 3:
            decls.append(f"<!ELEMENT {name(rng)} {rng.choice(DECLARATIONS_OF_ELEMENTS)}>")
        elif k == 4:
            decls.append("<!ENTITY % p '<!ENTITY t \"from a parameter\">'>%p;")
            text.append("t")
        elif k == 5:
            decls.append(rng.choice(["<!-- c -->", "<?p d?>", "\n", " "]))
        elif k == 6:
            decls.append("<!NOTATION n SYSTEM 'n'><!ENTITY w SYSTEM 'w.bin' NDATA n>")
        else:
            decls.append(rng.choice(["<!ENTITY % q SYSTEM 'q.dtd'>%q;", "<!ENTITY x SYSTEM 'x.xml'>"]))
    external = rng.choice(["", "", "", " SYSTEM 'a.dtd'", " PUBLIC '-//X//Y' 'y.dtd'"])
    return f"<!DOCTYPE {name(rng)}{external} [{''.join(decls)}]>", text, markup


def attributes(rng, text=()):
    out, used = "", set()
    for _ in range(rng.choice([0, 0, 1, 2, 3])):
        n = name(rng)
        if n in used:
            continue
        used.add(n)
        q = rng.choice("\"'")
        value = rng.choice(["", "v", "a b", "&amp;", "&#65;", "é", "x\ty", "z", "a>b", "&lt;"] + [f"&{e};" for e in text])
        out += f" {n}{rng.choice(['=', ' = ', '= '])}{q}{value}{q}"
    return out


def element(rng, depth, text=(), markup=()):
    n = name(rng)
    start = f"<{n}{attributes(rng, text)}"
    if depth == 0 or rng.random() < 0.1:
        start += rng.choice(DECLARATIONS)
    if rng.random() < 0.2:
        return start + rng.choice(["/>", " />"])
    body = ""
    refs = [f"&{e};" for e in list(text) + list(markup)]
    for _ in range(rng.choice([0, 1, 1, 2, 3]) if depth < 4 else 0):
        body += element(rng, depth + 1, text, markup) if rng.random() < 0.5 else rng.choice(TEXTS + refs * 3)
    return f"{start}>{body}</{n}>"


def document(rng):
    prolog = rng.choice(["", "", "<?xml version=\"1.0\"?>", "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\n",
                         "﻿", "<!-- p -->", "<?pi x?>\n"])
    epilog = rng.choice(["", "", "\n", "<!-- e -->", "<?pi?>", " \n<!--x-->\n"])
    doctype, text, markup = subset(rng) if rng.random() < 0.4 else ("", [], [])
    return (prolog + doctype + element(rng, 0, text, markup) + epilog).encode("utf-8")


def conformance_texts():
    out = []
    for path in sorted(glob.glob(os.path.join(ROOT, "xml/test/conformance/files/**/*.xml"), recursive=True)):
        with open(path, "rb") as f:
            out.append(f.read())
    return out


def mutate(rng, text, steps):
    t = bytearray(text)
    for _ in range(steps):
        op = rng.randrange(6)
        at = rng.randrange(len(t) + 1)
        if op == 0 and t:
            del t[min(at, len(t) - 1)]
        elif op == 1:
            t[at:at] = rng.choice(TRICKY)
        elif op == 2 and t:
            t[min(at, len(t) - 1)] = rng.randrange(256)
        elif op == 3:
            t = t[:at]
        elif op == 4 and t:
            hi = min(len(t), at + rng.randrange(1, 12))
            t[at:at] = t[at:hi]
        else:
            t[at:at] = bytes([rng.choice(b"<>&;/=\"' ")])
    return bytes(t)


def expat(text):
    """Whether expat accepts `text`, or its error offset."""
    # Expat refuses a namespace name holding its separator, and no XML 1.0 text holds U+0001.
    p = xml.parsers.expat.ParserCreate(namespace_separator="\x01")
    p.SetParamEntityParsing(xml.parsers.expat.XML_PARAM_ENTITY_PARSING_ALWAYS)
    try:
        p.Parse(text, True)
    except xml.parsers.expat.ExpatError as e:
        return p.ErrorByteIndex
    return None


def libxml2(text):
    """Whether xmllint accepts `text`, or None when it is not installed."""
    try:
        done = subprocess.run(["xmllint", "--noout", "--nonet", "-"], input=text, capture_output=True, timeout=20)
    except FileNotFoundError:
        return None
    return done.returncode == 0


def verdicts(binary, texts):
    """The oracle's verdict on each text: (None, "") for acceptance, or the offset and the rule's code of the refusal."""
    frame = b"".join(struct.pack("<I", len(t)) + t for t in texts)
    done = subprocess.run([binary], input=frame, capture_output=True, timeout=600)
    assert done.returncode == 0, f"{binary} exited {done.returncode}: {done.stderr.decode(errors='replace')[:400]}"
    lines = done.stdout.decode().splitlines()
    assert len(lines) == len(texts), f"{binary} answered {len(lines)} of {len(texts)} texts"
    return [(None, "") if line == "ok" else (int(line.split()[1]), line.split()[2]) for line in lines]


@pytest.fixture(scope="module")
def oracle(odin, tmp_path_factory):
    binary = str(tmp_path_factory.mktemp("xml") / "xml_oracle")
    subprocess.run([odin, "build", os.path.dirname(__file__), "-o:minimal", f"-out:{binary}"], cwd=ROOT, check=True)
    if shutil.which("xmllint") is None:
        warnings.warn("xmllint is not installed, so no verdict is settled by libxml2")
    return binary


def test_stury_reads_as_expat(oracle, seed, request):
    rng = random.Random(seed)
    corpus = conformance_texts()
    texts = []
    while len(texts) < (request.config.getoption("--cases") or CASES):
        base = rng.choice(corpus) if corpus and rng.random() < 0.15 else document(rng)
        text = base if rng.random() < 0.2 else mutate(rng, base, rng.choice([1, 1, 1, 2, 3]))
        if any(test(text) for _, test in SKIP):
            continue
        texts.append(text)
    differ, offsets = [], 0
    for text, (mine, code) in zip(texts, verdicts(oracle, texts)):
        if code == "entity_respelled":
            continue
        theirs = expat(text)
        if (mine is None) != (theirs is None):
            if libxml2(text) != (mine is None):
                differ.append(f"stury {'accepts' if mine is None else f'refuses at {mine}'}, expat "
                              f"{'accepts' if theirs is None else f'refuses at {theirs}'}: {text!r}")
        elif mine is not None and mine != theirs:
            offsets += 1
    assert not differ, f"{len(differ)} of {len(texts)} texts differ in the verdict ({offsets} more in the offset alone):\n" + "\n".join(differ)
