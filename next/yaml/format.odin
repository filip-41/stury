package yaml

import "stury:lib/core/tape"

// YAML 1.2 format handles, node spelling layout, container bounds (`close_end`), and spelled facts (`spelled_fact`).

// A YAML grammar variant. Both use YAML 1.2 Core Schema resolution (`!!str`, `!!int`, `!!float`, `!!bool`, `!!null`,
// `!!binary`); `.Yaml_Merge` also applies `<<` mapping merge keys during the walk.
Spec :: enum u8 {
	Yaml_1_2,
	Yaml_Merge,
}

// Options of a YAML read. `budget` limits depth, nodes, memory, steps and alias `expansion`. YAML takes no tolerances
// (`Bad_Option{"tolerate"}`) and no format-specific options (`Bad_Option{"format"}`).
Options :: tape.Options

// Format id base for YAML specs (`FORMAT_ID_XML + 1`, wired into central `tape` constants when merged).
@(private)
ID :: tape.Format_Id(14)

// Fact kinds recorded by YAML walks.
@(private)
FACTS :: tape.COMMENTS + {.Tag, .Anchor, .Alias, .Style, .Directive}

// Format capabilities: YAML values depend on document context (anchors/directives/indentation), keys are judged at
// object close under `.Last`/`.Refuse`, and inputs are UTF-8 text.
@(private)
CAPS :: tape.Caps{}

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Yaml_1_2 = {
		name      = "yaml",
		id        = ID + tape.Format_Id(Spec.Yaml_1_2),
		facts     = FACTS,
		caps      = CAPS,
		dups      = .Last,
		refuses   = {.Invalid_Utf8},
		bounds    = bounds,
		decode    = text_decoded,
		number    = number_value,
		same_text = same_text,
		key_hash  = key_hash,
		room      = decode_room,
		close_end = close_end,
		fact_name = spelled_fact,
	},
	.Yaml_Merge = {
		name      = "yaml-merge",
		id        = ID + tape.Format_Id(Spec.Yaml_Merge),
		facts     = FACTS,
		caps      = CAPS,
		dups      = .Last,
		refuses   = {.Invalid_Utf8},
		bounds    = bounds,
		decode    = text_decoded,
		number    = number_value,
		same_text = same_text,
		key_hash  = key_hash,
		room      = decode_room,
		close_end = close_end,
		fact_name = spelled_fact,
	},
}

// The format handle of `spec`, to pass to `tape` / `schema` / `write` / `edit` calls, or nil when `spec` is out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// Container spelling flag inside `tape.CONTAINER_STYLE` (`0x6000`) indicating a `[...]` or `{...}` flow collection
// (as opposed to block collections and single-pair implicit mappings inside flow sequences).
@(private)
STYLE_FLOW :: u16(1 << 13)

// Non-`.Number` scalar style bits stored at bits `11..12` (clear of `tape.SPELLING_DECODE`, `SPELLING_QUOTED`,
// `SPELLING_LAX`, `SPELLING_PLACED`, `SPELLING_ASCII`, and `SPELLING_CREDIT_EXACT`).
@(private)
STYLE_SHIFT :: 11
@(private)
STYLE_MASK :: u16(3) << STYLE_SHIFT
@(private)
STYLE_EXPLICIT :: u16(1 << 13)
@(private)
MAX_BLOCK_INDENT :: 127

// How a non-`.Number` scalar node is written.
@(private)
Style :: enum u8 {
	Plain,
	Single,
	Double,
	Block,
}

// How a `.Number` node is written, stored in bits `0..3` (`tape.NUMBER_KIND`). Values past `Forced_Float` do not share
// digit-count bits; `Block_*` reuse bits `6..10` + `13..15` for explicit block indentation.
@(private)
Number_Spelling :: enum u16 {
	Plain               = 0,  // unquoted RFC 8259 decimal (schema_check fast path)
	Decimal             = 1,  // non-strict YAML decimal (`007`, `+3`, `.5`, `5.`, `-00`)
	Hex                 = 2,  // unquoted `0x...`
	Octal               = 3,  // unquoted `0o...`
	Inf                 = 4,  // unquoted `.inf`, `+.Inf`, `-.INF`
	Nan                 = 5,  // unquoted `.nan`, `.NaN`, `.NAN`
	Forced_Float        = 6,  // unquoted decimal/radix coerced by `!!float`
	Quoted_Decimal      = 7,  // single/double-quoted `!!int` or `!!float` decimal
	Quoted_Hex          = 8,  // single/double-quoted `0x...` under `!!int`/`!!float`
	Quoted_Octal        = 9,  // single/double-quoted `0o...` under `!!int`/`!!float`
	Quoted_Inf          = 10, // single/double-quoted `.inf` under `!!float`
	Quoted_Nan          = 11, // single/double-quoted `.nan` under `!!float`
	Quoted_Forced_Float = 12, // single/double-quoted decimal/radix coerced by `!!float`
	Block_Num           = 13, // block scalar under `!!int` or `!!float` (decimal/radix/inf/nan)
	Block_Forced_Float  = 14, // block scalar integer coerced by `!!float`
}

#assert(u16(max(Number_Spelling)) <= tape.NUMBER_KIND)
#assert(1 << STYLE_SHIFT > tape.SPELLING_CREDIT_EXACT)

@(private)
style_of :: #force_inline proc "contextless" (spelling: u16) -> Style {
	return Style((spelling & STYLE_MASK) >> STYLE_SHIFT)
}

@(private)
style_bits :: #force_inline proc "contextless" (s: Style) -> u16 {
	return u16(s) << STYLE_SHIFT
}

// Encodes explicit block indentation `ci` (`0..127`) alongside `STYLE_EXPLICIT` without touching bits `0..5` or `11..12`.
@(private)
block_indent_bits :: #force_inline proc "contextless" (ci: int) -> u16 {
	u := u16(ci)
	return STYLE_EXPLICIT | ((u & 0x1F) << 6) | (((u >> 5) & 0x3) << 14)
}

// Returns the explicit block indentation (`0..127`), or `-1` when auto-detected.
@(private)
block_explicit_indent :: #force_inline proc "contextless" (spelling: u16) -> int {
	if spelling & STYLE_EXPLICIT == 0 {
		return -1
	}
	return int(((spelling >> 6) & 0x1F) | (((spelling >> 14) & 0x3) << 5))
}

@(private)
number_is_quoted :: #force_inline proc "contextless" (nk: Number_Spelling) -> bool {
	return nk >= .Quoted_Decimal && nk <= .Quoted_Forced_Float
}

@(private)
number_is_block :: #force_inline proc "contextless" (nk: Number_Spelling) -> bool {
	return nk >= .Block_Num
}

@(private)
number_is_forced_float :: #force_inline proc "contextless" (nk: Number_Spelling) -> bool {
	return nk == .Forced_Float || nk == .Quoted_Forced_Float || nk == .Block_Forced_Float
}

// Scalar byte-bounds around `t`'s span: `(1, 1)` for single- or double-quoted scalars (and quoted numbers) whose span
// starts past their opening quote and ends before their closing quote; `(0, 0)` for plain and block scalars.
@(private)
bounds :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	if t.kind > .Plain {
		return 0, 0
	}
	if t.kind == .Number {
		if number_is_quoted(Number_Spelling(t.spelling & tape.NUMBER_KIND)) {
			return 1, 1
		}
		return 0, 0
	}
	q := u8(t.spelling & tape.SPELLING_QUOTED != 0)
	return q, q
}

@(private)
is_flow :: #force_inline proc "contextless" (doc: ^tape.Document, n: tape.Node) -> bool {
	return n.spelling & tape.CONTAINER_STYLE == STYLE_FLOW
}

// The offset just past container `at` of `doc` in `doc.src`. Handles in-order containers iteratively as well as
// out-of-order children emitted by aliases and `<<` merge keys, with a fixed local unwind stack so deep chains cannot
// grow the native call stack.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) #no_bounds_check {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	ordered := .Alias not_in doc.present && doc.format != &FORMATS[.Yaml_Merge]
	Close_Frame :: struct {
		aliases: int,
		flows:   int,
	}
	unwind: [256]Close_Frame = ---
	sp := 0
	flows := 0
	end: u64
	j := at
	for {
		n := doc.nodes[j]
		if n.kind <= .Plain {
			_, tail := bounds(doc.src, n)
			end = n.lo + u64(n.n) + u64(tail)
			break
		}
		flow := is_flow(doc, n)
		if flow {
			flows += 1
		}
		if n.n <= 1 {
			end = n.lo + u64(flow)
			break
		}
		if ordered {
			last := j + 1
			for k := last; k < j + tape.Node_Index(n.n); k = tape.node_after(doc, k) {
				last = k
			}
			j = last
			continue
		}
		last, authored, aliases := j + 1, tape.NO_NODE, 0
		floor := n.lo
		limit := j + tape.Node_Index(n.n)
		for k := last; k < limit; k = tape.node_after(doc, k) {
			last = k
			lo := doc.nodes[k].lo
			if lo < floor || lo < doc.nodes[k - 1].lo || k - 1 != j && (lo == floor || lo == doc.nodes[k - 1].lo) {
				aliases += 1
			} else {
				authored, aliases, floor = k, 0, lo
			}
		}
		if flow && (aliases > 0 || doc.format == &FORMATS[.Yaml_Merge]) {
			end = flow_close_end(doc.src, n.lo)
			flows -= 1
			break
		}
		if aliases > 0 {
			if authored == tape.NO_NODE || sp == len(unwind) {
				end = past_aliases(doc.src, n.lo, aliases)
				break
			}
			unwind[sp] = {aliases = aliases, flows = flows}
			sp += 1
			flows = 0
			j = authored
			continue
		}
		j = last
	}
	for {
		end = past_flow_closes(doc.src, end, flows)
		if sp == 0 {
			return end, true
		}
		sp -= 1
		end = past_aliases(doc.src, end, unwind[sp].aliases)
		flows = unwind[sp].flows
	}
}

@(private = "file")
past_flow_closes :: proc "contextless" (src: []u8, from: u64, flows: int) -> u64 #no_bounds_check {
	at := from
	for _ in 0 ..< flows {
		bracket: for at < u64(len(src)) {
			switch src[at] {
			case ' ', '\t', '\r', '\n', ',':
				at += 1
			case '#':
				if at == 0 || src[at - 1] == ' ' || src[at - 1] == '\t' || src[at - 1] == '\r' || src[at - 1] == '\n' {
					for at < u64(len(src)) && src[at] != '\n' && src[at] != '\r' {
						at += 1
					}
				} else {
					at += 1
					break bracket
				}
			case:
				at += 1
				break bracket
			}
		}
	}
	return at
}

// The byte past the `count`th alias name from `from` in a block collection.
@(private = "file")
past_aliases :: proc "contextless" (src: []u8, from: u64, count: int) -> u64 #no_bounds_check {
	end := from
	for _ in 0 ..< count {
		at := end
		for at < u64(len(src)) {
			switch src[at] {
			case ' ', '\t', '\r', '\n', ',', ':', '?', '-', '<', '[', ']':
				at += 1
				continue
			case '#':
				if at == 0 || src[at - 1] == ' ' || src[at - 1] == '\t' || src[at - 1] == '\r' || src[at - 1] == '\n' {
					for at < u64(len(src)) && src[at] != '\n' && src[at] != '\r' {
						at += 1
					}
					continue
				}
			}
			break
		}
		if at >= u64(len(src)) || src[at] != '*' {
			return end
		}
		at += 1
		for at < u64(len(src)) {
			b := src[at]
			if b == ' ' || b == '\t' || b == '\r' || b == '\n' || b == ',' || b == '[' || b == ']' || b == '{' || b == '}' {
				break
			}
			at += 1
		}
		end = at
		for end < u64(len(src)) && (src[end] == ' ' || src[end] == ',') {
			end += 1
		}
		if end < u64(len(src)) && src[end] == ']' {
			end += 1
		} else {
			end = at
		}
	}
	return end
}

// The byte past the closing bracket of the flow collection opening at `lo` in `src`.
@(private)
flow_close_end :: proc "contextless" (src: []u8, lo: u64) -> u64 #no_bounds_check {
	depth := 0
	at := lo
	for at < u64(len(src)) {
		c := src[at]
		at += 1
		switch c {
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
			if depth == 0 {
				return at
			}
		case '"', '\'':
			for at < u64(len(src)) {
				b := src[at]
				if c == '"' && b == '\\' {
					at += 2
					continue
				}
				if b == c {
					if c == '\'' && at + 1 < u64(len(src)) && src[at + 1] == '\'' {
						at += 2
						continue
					}
					at += 1
					break
				}
				at += 1
			}
		case '#':
			if at >= 2 && (src[at - 2] == ' ' || src[at - 2] == '\t' || src[at - 2] == '\r' || src[at - 2] == '\n') {
				for at < u64(len(src)) && src[at] != '\n' && src[at] != '\r' {
					at += 1
				}
			}
		}
	}
	return min(at, u64(len(src)))
}

@(private, rodata)
STYLE_NAMES := [Style]string {
	.Plain  = "plain",
	.Single = "single",
	.Double = "double",
	.Block  = "block",
}

// The facts a YAML node spells in its node spelling: `.Style` ("flow"/"block" for containers, "plain"/"single"/"double"/
// "literal"/"folded" for scalars, and "hex"/"octal" for unquoted hex/octal integers).
@(private)
spelled_fact :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (string, bool) #no_bounds_check {
	if kind != .Style {
		return "", false
	}
	n := doc.nodes[at]
	switch n.kind {
	case .Array, .Object:
		return "flow" if is_flow(doc, n) else "block", true
	case .Number:
		nk := Number_Spelling(n.spelling & tape.NUMBER_KIND)
		switch nk {
		case .Hex:
			return "hex", true
		case .Octal:
			return "octal", true
		case .Quoted_Decimal ..= .Quoted_Forced_Float:
			return "single" if style_of(n.spelling) == .Single else "double", true
		case .Block_Num, .Block_Forced_Float:
			span := tape.span_bytes(doc, n.lo, n.n)
			return "folded" if len(span) > 0 && span[0] == '>' else "literal", true
		case .Plain, .Decimal, .Inf, .Nan, .Forced_Float:
			return "plain", true
		}
	case .Null, .False, .True, .Bytes, .String, .Plain:
		st := style_of(n.spelling)
		if st == .Block {
			span := tape.span_bytes(doc, n.lo, n.n)
			return "folded" if len(span) > 0 && span[0] == '>' else "literal", true
		}
		return STYLE_NAMES[st], true
	case .End:
	}
	return "", false
}
