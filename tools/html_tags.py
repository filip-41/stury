#!/usr/bin/env python3
"""Write html/tags.odin: the `Tag` enum of the element names HTML's tree construction treats by name, their names,
the categories and scopes the standard puts each in, and an open-addressed table that finds a name's tag. Then the
names foreign content treats by name, from the standard's tables: the SVG element and attribute names whose case it
adjusts, MathML's `definitionURL`, the attributes it puts in a namespace, and the elements that are integration points,
in a second table of the same shape.

A name's slot is `((w ~ n) * MUL) >> (64 - BITS)`, `w` its first eight bytes with each byte's 0x20 bit set (ASCII
letters lowered) loaded little-endian and padded with zeros, `n` its length. A slot holds 0 for none or 1 + an entry,
and a lookup steps to the next slot until it finds the name or a 0. The multiplier is the first one, counting up from
a fixed seed, whose longest probe is the shortest found within the search, and among those whose probes sum least.

Run from the repository root:
    python3 tools/html_tags.py
"""

OUT = "html/tags.odin"
BITS = 9
FOREIGN_BITS = 8
SEED = 0x9E3779B97F4A7C15

# Every name section 13.2.6 of the HTML standard names in its insertion modes, scopes and categories, and in the rules
# for foreign content. A `Tags` set is a u128, so there are fewer than 128.
NAMES = """
a address applet area article aside b base basefont bgsound big blockquote body br button caption center code col
colgroup dd details dialog dir div dl dt em embed fieldset figcaption figure font footer form frame frameset h1 h2 h3
h4 h5 h6 head header hgroup hr html i iframe image img input keygen li link listing main marquee math menu meta nav
nobr noembed noframes noscript object ol optgroup option p param plaintext pre rb rp rt rtc ruby s script search
section select small source strike strong style summary svg table tbody td template textarea tfoot th thead title tr
track tt u ul wbr xmp span sub sup var mglyph malignmark selectedcontent datalist
""".split()

# The standard's lists, by the class each gives an HTML element. `Scope` is the elements that bound "in scope", which
# list item, button and table scope add to or replace. `Open_At_End` is the elements a body may hold open at its end
# with no parse error. The contexts are the elements the stack is cleared back to. `Breakout` is the start tags that
# end foreign content, `font` aside, and `Thorough_End` the elements implied end tags close thoroughly.
CLASSES = {
    "Special": """address applet area article aside base basefont bgsound blockquote body br button caption center col
        colgroup dd details dir div dl dt embed fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6
        head header hgroup hr html iframe img input keygen li link listing main marquee menu meta nav noembed noframes
        noscript object ol p param plaintext pre script search section select source style summary table tbody td
        template textarea tfoot th thead title tr track ul wbr xmp""",
    "Formatting": "a b big code em font i nobr s small strike strong tt u",
    "Scope": "applet caption html table td th marquee object select template",
    "List_Scope": "ol ul",
    "Button_Scope": "button",
    "Table_Scope": "html table template",
    "Implied_End": "dd dt li optgroup option p rb rp rt rtc",
    "Open_At_End": "dd dt li optgroup option p rb rp rt rtc tbody td tfoot th thead tr body html",
    "Foster": "table tbody tfoot thead tr",
    "Heading": "h1 h2 h3 h4 h5 h6",
    "Body_Context": "tbody tfoot thead template html",
    "Row_Context": "tr template html",
    "Breakout": """b big blockquote body br center code dd div dl dt em embed h1 h2 h3 h4 h5 h6 head hr i img li listing
        menu meta nobr ol p pre ruby s small span strong strike sub sup table tt u ul var""",
    "Thorough_End": "caption colgroup dd dt li optgroup option p rb rp rt rtc tbody td tfoot th thead tr",
}

# The standard's "adjust SVG tag names" table, by the adjusted name: the name it replaces is its ASCII lowercase.
SVG_ELEMENTS = """altGlyph altGlyphDef altGlyphItem animateColor animateMotion animateTransform clipPath feBlend
feColorMatrix feComponentTransfer feComposite feConvolveMatrix feDiffuseLighting feDisplacementMap feDistantLight
feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feImage feMerge feMergeNode feMorphology feOffset
fePointLight feSpecularLighting feSpotLight feTile feTurbulence foreignObject glyphRef linearGradient radialGradient
textPath""".split()

# "Adjust SVG attributes", by the adjusted name.
SVG_ATTRIBUTES = """attributeName attributeType baseFrequency baseProfile calcMode clipPathUnits diffuseConstant
edgeMode filterUnits glyphRef gradientTransform gradientUnits kernelMatrix kernelUnitLength keyPoints keySplines
keyTimes lengthAdjust limitingConeAngle markerHeight markerUnits markerWidth maskContentUnits maskUnits numOctaves
pathLength patternContentUnits patternTransform patternUnits pointsAtX pointsAtY pointsAtZ preserveAlpha
preserveAspectRatio primitiveUnits refX refY repeatCount repeatDur requiredExtensions requiredFeatures
specularConstant specularExponent spreadMethod startOffset stdDeviation stitchTiles surfaceScale systemLanguage
tableValues targetX targetY textLength viewBox viewTarget xChannelSelector yChannelSelector zoomAndPan""".split()

# "Adjust MathML attributes".
MATH_ATTRIBUTES = ["definitionURL"]

# "Adjust foreign attributes": the name as the token holds it, its prefix, local name and namespace.
FOREIGN_ATTRIBUTES = [
    ("xlink:actuate", "xlink", "actuate", "Xlink"),
    ("xlink:arcrole", "xlink", "arcrole", "Xlink"),
    ("xlink:href", "xlink", "href", "Xlink"),
    ("xlink:role", "xlink", "role", "Xlink"),
    ("xlink:show", "xlink", "show", "Xlink"),
    ("xlink:title", "xlink", "title", "Xlink"),
    ("xlink:type", "xlink", "type", "Xlink"),
    ("xml:lang", "xml", "lang", "Xml"),
    ("xml:space", "xml", "space", "Xml"),
    ("xmlns", "", "xmlns", "Xmlns"),
    ("xmlns:xlink", "xmlns", "xlink", "Xmlns"),
]

# The foreign elements the tree construction treats by name: MathML's text integration points, `annotation-xml`, and
# SVG's HTML integration points. Each is a special element that bounds every scope but the table scope.
MATH_TEXT = "mi mo mn ms mtext".split()
MATH_ANNOTATION = ["annotation-xml"]
SVG_INTEGRATION = "foreignobject desc title".split()

MASK64 = (1 << 64) - 1


def key(name):
    w = 0
    for i, c in enumerate(name.encode()[:8]):
        w |= (c | 0x20) << (8 * i)
    return w ^ len(name)


def place(names, bits, mul):
    slots = [0] * (1 << bits)
    longest = total = 0
    for i, name in enumerate(names, 1):
        h = ((key(name) * mul) & MASK64) >> (64 - bits)
        probe = 1
        while slots[h]:
            h = (h + 1) & ((1 << bits) - 1)
            probe += 1
        slots[h] = i
        longest = max(longest, probe)
        total += probe
    return slots, (longest, total)


def search(names, bits):
    best = None
    mul = SEED
    for _ in range(4096):
        slots, cost = place(names, bits, mul | 1)
        if best is None or cost < best[1]:
            best = (mul | 1, cost, slots)
        mul = (mul * 6364136223846793005 + 1442695040888963407) & MASK64
    return best[0], best[1][0], best[2]


def foreign_entries():
    """The foreign names by their ASCII lowercase: the spelling written, its prefix, namespace and kinds."""
    entries = {}

    def add(lowered, name, kind, prefix="", ns="None"):
        e = entries.setdefault(lowered, {"name": name, "prefix": prefix, "ns": ns, "kinds": []})
        assert (e["name"], e["prefix"], e["ns"]) == (name, prefix, ns), lowered
        e["kinds"].append(kind)

    for n in SVG_ELEMENTS:
        add(n.lower(), n, "Svg_Element")
    for n in SVG_ATTRIBUTES:
        add(n.lower(), n, "Svg_Attribute")
    for n in MATH_ATTRIBUTES:
        add(n.lower(), n, "Math_Attribute")
    for qualified, prefix, local, ns in FOREIGN_ATTRIBUTES:
        add(qualified, local, "Foreign_Attribute", prefix, ns)
    for n in MATH_TEXT:
        add(n, n, "Math_Text")
    for n in MATH_ANNOTATION:
        add(n, n, "Math_Annotation")
    for n in SVG_INTEGRATION:
        add(n, next((s for s in SVG_ELEMENTS if s.lower() == n), n), "Svg_Integration")
    return entries


def ada(name):
    return "_".join(part.capitalize() for part in name.replace("-", "_").split("_"))


def slot_rows(slots):
    return ["\t" + " ".join(f"{s}," for s in slots[i:i + 16]) for i in range(0, len(slots), 16)]


def main():
    assert len(NAMES) == len(set(NAMES)) and len(NAMES) < 128
    assert len(CLASSES) <= 16 and all(n in NAMES for names in CLASSES.values() for n in names.split())
    mul, longest, slots = search(NAMES, BITS)
    out = [
        "package html",
        "",
        "// Generated by tools/html_tags.py. Do not edit.",
        "// The element names the tree construction treats by name. `.Other` is every other name. A name's slot in",
        "// TAG_SLOTS is `((w ~ n) * TAG_MUL) >> (64 - TAG_BITS)`, `w` its first eight bytes with each byte's 0x20 bit",
        f"// set loaded little-endian, `n` its length, and a lookup reads at most {longest} slots from there.",
        "",
        "@(private)",
        "Tag :: enum u8 {",
        "\tOther,",
    ]
    out += [f"\t{ada(n)}," for n in NAMES]
    out += [
        "}",
        "",
        "@(private)",
        f"TAG_MUL :: 0x{mul:016x}",
        "@(private)",
        f"TAG_BITS :: {BITS}",
        "@(private)",
        f"TAG_LONGEST :: {max(len(n) for n in NAMES)}",
        "",
        "@(private, rodata)",
        "TAG_NAMES := [Tag]string {",
        '\t.Other = "",',
    ]
    out += [f'\t.{ada(n)} = "{n}",' for n in NAMES]
    out += ["}", "", "@(private)", "Tag_Class :: enum u8 {"]
    out += [f"\t{c}," for c in CLASSES]
    out += ["}", "", "@(private)", "Tag_Classes :: bit_set[Tag_Class; u16]", "", "@(private, rodata)",
            "TAG_CLASSES := #partial [Tag]Tag_Classes {"]
    for n in NAMES:
        got = [c for c, names in CLASSES.items() if n in names.split()]
        if got:
            out.append(f"\t.{ada(n)} = {{{', '.join('.' + c for c in got)}}},")
    out += ["}", "", "@(private, rodata)", f"TAG_SLOTS := [{1 << BITS}]u8 {{"]
    out += slot_rows(slots)
    out += ["}", ""]

    entries = foreign_entries()
    keys = sorted(entries)
    assert len(keys) < 255
    fmul, flongest, fslots = search(keys, FOREIGN_BITS)
    out += [
        "// The names foreign content treats by name, by their ASCII lowercase. A name's slot in FOREIGN_SLOTS is found",
        f"// as a tag's is, with FOREIGN_MUL and FOREIGN_BITS, and a lookup reads at most {flongest} slots from there.",
        "",
        "@(private)",
        f"FOREIGN_MUL :: 0x{fmul:016x}",
        "@(private)",
        f"FOREIGN_BITS :: {FOREIGN_BITS}",
        "@(private)",
        f"FOREIGN_LONGEST :: {max(len(k) for k in keys)}",
        "",
        "@(private, rodata)",
        "FOREIGN_NAMES := [?]Foreign_Name {",
        "\t{},",
    ]
    for k in keys:
        e = entries[k]
        kinds = ", ".join("." + c for c in e["kinds"])
        out.append(f'\t{{key = "{k}", name = "{e["name"]}", prefix = "{e["prefix"]}", ns = .{e["ns"]}, '
                   f'kinds = {{{kinds}}}}},')
    out += ["}", "", "@(private, rodata)", f"FOREIGN_SLOTS := [{1 << FOREIGN_BITS}]u8 {{"]
    out += slot_rows(fslots)
    out += ["}", ""]
    open(OUT, "w").write("\n".join(out))
    print(f"{OUT}: {len(NAMES)} tags, multiplier 0x{mul:016x}, longest probe {longest}; "
          f"{len(keys)} foreign names, multiplier 0x{fmul:016x}, longest probe {flongest}")


if __name__ == "__main__":
    main()
