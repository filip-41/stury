package css

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import core ".."

// CSS selectors over a markup document: the static part of Selectors Level 4, compiled once by `compile` and matched by
// `select`. A selector is held as flat runs: a list is a run of complex selectors, a complex selector a run of compounds
// from left to right, and a compound a run of tests, every one of which an element passes.

// A compiled selector list. Its runs index each other, and `text` holds every name and value with its escapes decoded.
// `destroy` frees it.
Selector :: struct {
	list:      Run,
	complexes: [dynamic]Complex,
	compounds: [dynamic]Compound,
	tests:     [dynamic]Test,
	text:      [dynamic]u8,
}

// A run of `n` entries of one of a selector's arrays, from `lo`.
@(private)
Run :: struct {
	lo, n: u32,
}

// How a compound relates to the one left of it, or for the first compound of a relative selector to the element
// `:has` tests.
@(private)
Combinator :: enum u8 {
	Descendant,
	Child,
	Next, // `+`
	Subsequent, // `~`
}

@(private)
Complex :: struct {
	compounds: Run,
	relative:  bool, // an argument of `:has`, whose first compound relates to the element tested
}

@(private)
Compound :: struct {
	tests:      Run,
	combinator: Combinator,
}

@(private)
Test_Kind :: enum u8 {
	Type,
	Attribute,
	Is, // `:is` and `:where`
	Not,
	Has,
	Root,
	Empty,
	Nth, // every `:nth-*` and the child and type positions, by `last`, `of_type` and `list`
}

@(private)
Attribute_Op :: enum u8 {
	Exists,
	Equals,
	Includes, // `~=`
	Dash, // `|=`
	Prefix, // `^=`
	Suffix, // `$=`
	Substring, // `*=`
}

// One test of a compound. `name` and `value` are runs of `text`, and `list` a run of `complexes`: the argument of
// `:is`, `:not` and `:has`, or the `of S` of `:nth-child`, empty for none. An element's position `p` passes `:nth`
// when `p = a*n + b` for some `n >= 0`.
@(private)
Test :: struct {
	kind:    Test_Kind,
	op:      Attribute_Op,
	fold:    bool, // the `i` flag: the value compares ASCII case-insensitively
	last:    bool, // counted from the last sibling
	of_type: bool, // counted among the siblings of the element's name
	name:    Run,
	value:   Run,
	list:    Run,
	a, b:    i64,
}

// The details of a selector's faults, `Fault.detail` under `RULES`.
Detail :: enum u8 {
	None,
	Syntax,
	Pseudo_Class,
	Pseudo_Element,
	Namespace,
}

// The fault table of a selector, which every fault `compile` returns points to.
@(rodata)
RULES := core.Rules {
	"css",
	{
		{},
		{"syntax", "Invalid selector"},
		{"pseudo_class", "Unsupported pseudo-class"},
		{"pseudo_element", "Unsupported pseudo-element"},
		{"namespace", "Unsupported namespace prefix"},
	},
}

// The deepest nesting of `:is`, `:not`, `:has` and `:nth-child(of S)` a selector holds.
MAX_NESTING :: 32

@(private)
Parser :: struct {
	src:   string,
	at:    int,
	sel:   ^Selector,
	depth: int,
	fault: core.Fault,
}

// Compiles the selector list `text` into a `Selector` in `allocator`. A text that is no selector list is a `Fault` under
// `RULES` at the byte that breaks it: `.Truncated` at the end of a text that stops inside a selector, `.Too_Deep` past
// `MAX_NESTING`, else `.Bad_Char` with the detail, which for a pseudo-class, a pseudo-element or a namespace prefix
// out of scope is at its first byte.
compile :: proc(text: string, allocator := context.allocator) -> (sel: Selector, err: core.Error) {
	sel = {
		complexes = make([dynamic]Complex, allocator),
		compounds = make([dynamic]Compound, allocator),
		tests = make([dynamic]Test, allocator),
		text = make([dynamic]u8, allocator),
	}
	p := Parser{src = text, sel = &sel}
	list, ok := parse_list(&p, false)
	if ok && p.at < len(p.src) {
		ok = refuse(&p, p.at, .Syntax)
	}
	if !ok {
		destroy(&sel)
		if p.fault.kind == .No_Memory {
			return {}, runtime.Allocator_Error.Out_Of_Memory
		}
		return {}, p.fault
	}
	sel.list = list
	return sel, nil
}

// Frees what `compile` made.
destroy :: proc(sel: ^Selector) {
	delete(sel.complexes)
	delete(sel.compounds)
	delete(sel.tests)
	delete(sel.text)
	sel^ = {}
}

// Records a fault at byte `at`, `.Truncated` when it is the end of the text, and returns false.
@(private)
refuse :: proc(p: ^Parser, at: int, detail: Detail, kind := core.Fault_Kind.Bad_Char) -> bool {
	k := kind
	if at >= len(p.src) && k == .Bad_Char {
		k = .Truncated
	}
	p.fault = {at = u64(at), rules = &RULES, kind = k, detail = u8(detail) if k == .Bad_Char else 0}
	return false
}

@(private)
no_memory :: proc(p: ^Parser) -> bool {
	p.fault = {kind = .No_Memory}
	return false
}

@(private)
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

// Skips white space and returns whether there was any.
@(private)
skip_spaces :: proc(p: ^Parser) -> bool {
	from := p.at
	for p.at < len(p.src) && is_space(p.src[p.at]) {
		p.at += 1
	}
	return p.at > from
}

@(private)
peek :: #force_inline proc(p: ^Parser, k := 0) -> u8 {
	return p.src[p.at + k] if p.at + k < len(p.src) else 0
}

// A list of complex selectors separated by commas, up to the end of the text or a `)`, appended to `complexes` as one
// run once every one is read, so the runs a nested list appends stand apart from it.
@(private)
parse_list :: proc(p: ^Parser, relative: bool) -> (list: Run, ok: bool) {
	if p.depth >= MAX_NESTING {
		return {}, refuse(p, p.at, .Syntax, .Too_Deep)
	}
	p.depth += 1
	defer p.depth -= 1
	read := make([dynamic]Complex, context.temp_allocator)
	for {
		push(p, &read, parse_complex(p, relative) or_return) or_return
		skip_spaces(p)
		if peek(p) != ',' {
			break
		}
		p.at += 1
	}
	return put_run(p, &p.sel.complexes, read[:])
}

@(private)
push :: proc(p: ^Parser, into: ^[dynamic]$T, item: T) -> bool {
	if _, err := append(into, item); err != nil {
		return no_memory(p)
	}
	return true
}

// Appends `items` to `into` and returns their run.
@(private)
put_run :: proc(p: ^Parser, into: ^[dynamic]$T, items: []T) -> (Run, bool) {
	lo := len(into)
	if _, err := append(into, ..items); err != nil {
		return {}, no_memory(p)
	}
	return {u32(lo), u32(len(items))}, true
}

@(private)
parse_complex :: proc(p: ^Parser, relative: bool) -> (c: Complex, ok: bool) {
	read := make([dynamic]Compound, context.temp_allocator)
	skip_spaces(p)
	comb := Combinator.Descendant
	if relative {
		comb = parse_combinator(p)
	}
	for {
		push(p, &read, parse_compound(p, comb) or_return) or_return
		spaced := skip_spaces(p)
		switch peek(p) {
		case 0, ',', ')':
			c.compounds = put_run(p, &p.sel.compounds, read[:]) or_return
			c.relative = relative
			return c, true
		case '>', '+', '~':
			comb = parse_combinator(p)
		case:
			if !spaced {
				return {}, refuse(p, p.at, .Syntax)
			}
			comb = .Descendant
		}
	}
}

// The combinator at the reader, and the white space after it, `Descendant` when there is none.
@(private)
parse_combinator :: proc(p: ^Parser) -> Combinator {
	comb := Combinator.Descendant
	switch peek(p) {
	case '>':
		comb = .Child
	case '+':
		comb = .Next
	case '~':
		comb = .Subsequent
	case:
		return comb
	}
	p.at += 1
	skip_spaces(p)
	return comb
}

@(private)
parse_compound :: proc(p: ^Parser, comb: Combinator) -> (c: Compound, ok: bool) {
	read := make([dynamic]Test, context.temp_allocator)
	start := p.at
	c.combinator = comb
	if peek(p) == '*' || peek(p) == '|' || ident_starts(p) {
		universal := peek(p) == '*'
		name: Run
		if universal {
			p.at += 1
		} else if peek(p) != '|' {
			name = parse_name(p) or_return
		}
		if peek(p) == '|' && peek(p, 1) != '=' {
			return {}, refuse(p, start, .Namespace)
		}
		if !universal {
			push(p, &read, Test{kind = .Type, name = name}) or_return
		}
	}
	for {
		t: Test
		switch peek(p) {
		case '#':
			p.at += 1
			if !ident_starts(p) {
				return {}, refuse(p, p.at, .Syntax)
			}
			t = {kind = .Attribute, op = .Equals, name = put_text(p, "id") or_return, value = parse_name(p) or_return}
		case '.':
			p.at += 1
			if !ident_starts(p) {
				return {}, refuse(p, p.at, .Syntax)
			}
			t = {kind = .Attribute, op = .Includes, name = put_text(p, "class") or_return, value = parse_name(p) or_return}
		case '[':
			t = parse_attribute(p) or_return
		case ':':
			t = parse_pseudo(p, &read) or_return
		case:
			if p.at == start {
				return {}, refuse(p, p.at, .Syntax)
			}
			c.tests = put_run(p, &p.sel.tests, read[:]) or_return
			return c, true
		}
		push(p, &read, t) or_return
	}
}

// `[name]`, or `[name op value flag]` with the value an identifier or a string and the flag `i` or `s`.
@(private)
parse_attribute :: proc(p: ^Parser) -> (t: Test, ok: bool) {
	start := p.at
	p.at += 1
	skip_spaces(p)
	t.kind = .Attribute
	if peek(p) == '|' || peek(p) == '*' {
		return {}, refuse(p, p.at, .Namespace)
	}
	if !ident_starts(p) {
		return {}, refuse(p, p.at, .Syntax)
	}
	t.name = parse_name(p) or_return
	if peek(p) == '|' && peek(p, 1) != '=' {
		return {}, refuse(p, start + 1, .Namespace)
	}
	skip_spaces(p)
	switch peek(p) {
	case ']':
		p.at += 1
		return t, true
	case '=':
		t.op = .Equals
		p.at += 1
	case '~', '|', '^', '$', '*':
		if peek(p, 1) != '=' {
			return {}, refuse(p, p.at + 1, .Syntax)
		}
		ops := [?]Attribute_Op{.Includes, .Dash, .Prefix, .Suffix, .Substring}
		t.op = ops[strings.index_byte("~|^$*", peek(p))]
		p.at += 2
	case:
		return {}, refuse(p, p.at, .Syntax)
	}
	skip_spaces(p)
	switch {
	case peek(p) == '"' || peek(p) == '\'':
		t.value = parse_string(p) or_return
	case ident_starts(p):
		t.value = parse_name(p) or_return
	case:
		return {}, refuse(p, p.at, .Syntax)
	}
	skip_spaces(p)
	if c := peek(p) | 0x20; (c == 'i' || c == 's') && !is_name_byte(peek(p, 1)) {
		t.fold = c == 'i'
		p.at += 1
		skip_spaces(p)
	}
	if peek(p) != ']' {
		return {}, refuse(p, p.at, .Syntax)
	}
	p.at += 1
	return t, true
}

// A pseudo-class: a structural one, or `:is`, `:where`, `:not`, `:has` and the `:nth-*` functions with their argument.
// `:only-child` and `:only-of-type` are two tests, the first of which goes into `read` here.
@(private)
parse_pseudo :: proc(p: ^Parser, read: ^[dynamic]Test) -> (t: Test, ok: bool) {
	start := p.at
	p.at += 1
	if peek(p) == ':' {
		return {}, refuse(p, start, .Pseudo_Element)
	}
	if !ident_starts(p) {
		return {}, refuse(p, p.at, .Syntax)
	}
	name_at := p.at
	for p.at < len(p.src) && is_name_byte(p.src[p.at]) {
		p.at += 1
	}
	name := p.src[name_at:p.at]
	if peek(p) != '(' {
		switch {
		case fold_equal(name, "root"):
			return {kind = .Root}, true
		case fold_equal(name, "empty"):
			return {kind = .Empty}, true
		case fold_equal(name, "first-child"):
			return {kind = .Nth, b = 1}, true
		case fold_equal(name, "last-child"):
			return {kind = .Nth, b = 1, last = true}, true
		case fold_equal(name, "first-of-type"):
			return {kind = .Nth, b = 1, of_type = true}, true
		case fold_equal(name, "last-of-type"):
			return {kind = .Nth, b = 1, last = true, of_type = true}, true
		case fold_equal(name, "only-child"), fold_equal(name, "only-of-type"):
			of_type := len(name) > len("only-child")
			push(p, read, Test{kind = .Nth, b = 1, of_type = of_type}) or_return
			return {kind = .Nth, b = 1, last = true, of_type = of_type}, true
		case fold_equal(name, "before"), fold_equal(name, "after"), fold_equal(name, "first-line"), fold_equal(name, "first-letter"):
			return {}, refuse(p, start, .Pseudo_Element)
		}
		return {}, refuse(p, start, .Pseudo_Class)
	}
	p.at += 1
	skip_spaces(p)
	switch {
	case fold_equal(name, "is"), fold_equal(name, "where"):
		t = {kind = .Is, list = parse_list(p, false) or_return}
	case fold_equal(name, "not"):
		t = {kind = .Not, list = parse_list(p, false) or_return}
	case fold_equal(name, "has"):
		t = {kind = .Has, list = parse_list(p, true) or_return}
	case fold_equal(name, "nth-child"), fold_equal(name, "nth-last-child"), fold_equal(name, "nth-of-type"), fold_equal(name, "nth-last-of-type"):
		t = {kind = .Nth, last = fold_equal(name[:min(8, len(name))], "nth-last"), of_type = fold_equal(name[len(name) - 7:], "of-type")}
		t.a, t.b = parse_nth(p) or_return
		if !t.of_type && skip_spaces(p) && fold_equal(p.src[p.at:min(p.at + 2, len(p.src))], "of") && !is_name_byte(peek(p, 2)) {
			p.at += 2
			t.list = parse_list(p, false) or_return
		}
	case:
		return {}, refuse(p, start, .Pseudo_Class)
	}
	skip_spaces(p)
	if peek(p) != ')' {
		return {}, refuse(p, p.at, .Syntax)
	}
	p.at += 1
	return t, true
}

// The `An+B` of an `:nth-*` argument: `odd`, `even`, an integer, or `An` with an optional signed `B`, white space
// allowed around the sign of `B` and nowhere inside `An`.
@(private)
parse_nth :: proc(p: ^Parser) -> (a, b: i64, ok: bool) {
	rest := p.src[p.at:]
	if len(rest) >= 3 && fold_equal(rest[:3], "odd") && !is_name_byte(peek(p, 3)) {
		p.at += 3
		return 2, 1, true
	}
	if len(rest) >= 4 && fold_equal(rest[:4], "even") && !is_name_byte(peek(p, 4)) {
		p.at += 4
		return 2, 0, true
	}
	sign := i64(1)
	if peek(p) == '+' || peek(p) == '-' {
		sign = -1 if peek(p) == '-' else 1
		p.at += 1
	}
	digits_at := p.at
	n := parse_digits(p)
	if peek(p) | 0x20 != 'n' {
		if p.at == digits_at {
			return 0, 0, refuse(p, p.at, .Syntax)
		}
		return 0, sign * n, true
	}
	a = sign * (n if p.at > digits_at else 1)
	p.at += 1
	save := p.at
	skip_spaces(p)
	if peek(p) != '+' && peek(p) != '-' {
		p.at = save
		return a, 0, true
	}
	sign = -1 if peek(p) == '-' else 1
	p.at += 1
	skip_spaces(p)
	digits_at = p.at
	n = parse_digits(p)
	if p.at == digits_at {
		return 0, 0, refuse(p, p.at, .Syntax)
	}
	return a, sign * n, true
}

// The decimal digits at the reader, saturated far past any position.
@(private)
parse_digits :: proc(p: ^Parser) -> i64 {
	n: i64
	for p.at < len(p.src) && p.src[p.at] - '0' < 10 {
		n = min(n * 10 + i64(p.src[p.at] - '0'), 1 << 40)
		p.at += 1
	}
	return n
}

@(private)
is_name_byte :: #force_inline proc(c: u8) -> bool {
	return c - 'a' < 26 || c - 'A' < 26 || c - '0' < 10 || c == '-' || c == '_' || c >= 0x80
}

// Whether an escape starts at byte `k` past the reader: a backslash not followed by a line end.
@(private)
escape_at :: proc(p: ^Parser, k: int) -> bool {
	return peek(p, k) == '\\' && peek(p, k + 1) != '\n' && peek(p, k + 1) != '\r' && peek(p, k + 1) != '\f'
}

// Whether an identifier starts at the reader.
@(private)
ident_starts :: proc(p: ^Parser) -> bool {
	k := 1 if peek(p) == '-' else 0
	c := peek(p, k)
	if k == 1 && c == '-' {
		return true
	}
	return c - 'a' < 26 || c - 'A' < 26 || c == '_' || c >= 0x80 || escape_at(p, k)
}

// Whether a name character or an escape is at the reader.
@(private)
name_continues :: proc(p: ^Parser) -> bool {
	return p.at < len(p.src) && is_name_byte(p.src[p.at]) || escape_at(p, 0)
}

// The name characters and escapes at the reader, decoded into the selector's text.
@(private)
parse_name :: proc(p: ^Parser) -> (r: Run, ok: bool) {
	lo := len(p.sel.text)
	for name_continues(p) {
		if p.src[p.at] == '\\' {
			put_escape(p) or_return
			continue
		}
		push(p, &p.sel.text, p.src[p.at]) or_return
		p.at += 1
	}
	return {u32(lo), u32(len(p.sel.text) - lo)}, true
}

// A quoted string, its escapes decoded and an escaped line end dropped. A line end in it is a fault.
@(private)
parse_string :: proc(p: ^Parser) -> (r: Run, ok: bool) {
	quote := p.src[p.at]
	p.at += 1
	lo := len(p.sel.text)
	for {
		if p.at >= len(p.src) {
			return {}, refuse(p, p.at, .Syntax)
		}
		switch c := p.src[p.at]; {
		case c == quote:
			p.at += 1
			return {u32(lo), u32(len(p.sel.text) - lo)}, true
		case c == '\n' || c == '\r' || c == '\f':
			return {}, refuse(p, p.at, .Syntax)
		case c == '\\':
			if next := peek(p, 1); next == '\n' || next == '\f' {
				p.at += 2
			} else if next == '\r' {
				p.at += 3 if peek(p, 2) == '\n' else 2
			} else if p.at + 1 < len(p.src) {
				put_escape(p) or_return
			} else {
				p.at += 1
			}
		case:
			push(p, &p.sel.text, c) or_return
			p.at += 1
		}
	}
}

// The escape at the reader: up to six hex digits and one white space after them, the code point's UTF-8 (U+FFFD for
// zero, a surrogate or one past U+10FFFF), or the character after the backslash as it stands.
@(private)
put_escape :: proc(p: ^Parser) -> bool {
	p.at += 1
	if p.at >= len(p.src) {
		return put_rune(p, utf8.RUNE_ERROR)
	}
	cp: u32
	digits := 0
	for digits < 6 && p.at < len(p.src) {
		c := p.src[p.at]
		v := u32(c - '0') if c - '0' < 10 else u32((c | 0x20) - 'a' + 10) if (c | 0x20) - 'a' < 6 else 16
		if v == 16 {
			break
		}
		cp = cp * 16 + v
		digits += 1
		p.at += 1
	}
	if digits == 0 {
		p.at += 1
		return push(p, &p.sel.text, p.src[p.at - 1])
	}
	if p.at + 1 < len(p.src) && p.src[p.at] == '\r' && p.src[p.at + 1] == '\n' {
		p.at += 2
	} else if p.at < len(p.src) && is_space(p.src[p.at]) {
		p.at += 1
	}
	if cp == 0 || cp - 0xD800 < 0x800 || cp > 0x10FFFF {
		cp = u32(utf8.RUNE_ERROR)
	}
	return put_rune(p, rune(cp))
}

@(private)
put_rune :: proc(p: ^Parser, r: rune) -> bool {
	b, n := utf8.encode_rune(r)
	_, err := append(&p.sel.text, ..b[:n])
	return err == nil || no_memory(p)
}

@(private)
put_text :: proc(p: ^Parser, s: string) -> (Run, bool) {
	lo := len(p.sel.text)
	if _, err := append(&p.sel.text, s); err != nil {
		return {}, no_memory(p)
	}
	return {u32(lo), u32(len(s))}, true
}

// Whether `a` and `b` are equal with their ASCII letters compared case-insensitively.
@(private)
fold_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if fold(a[i]) != fold(b[i]) {
			return false
		}
	}
	return true
}

@(private)
fold :: #force_inline proc(c: u8) -> u8 {
	return c | 0x20 if c - 'A' < 26 else c
}
