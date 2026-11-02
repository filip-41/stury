package core

import "base:runtime"
import "core:unicode/utf8"
import spell "./spell"

// A path is a chain of steps from a value, spelled as jq text, as an RFC 6901 JSON Pointer, or as an Odin `Path` of step
// literals. Each spelling gives the same `Path`.

// The most steps a path holds, since `Path.optional` holds one bit per step.
MAX_STEPS :: 64
// The most paths one read holds, since the engine keeps a bit per path.
MAX_PATHS :: 64

// A member by its decoded key.
Name :: distinct string
// An element, negative from the end.
Index :: distinct int
// Every member or element.
All :: struct {}
// The elements from `lo` up to `hi`, each negative from the end, and `hi` nil for all the rest.
Slice :: struct {
	lo: int,
	hi: Maybe(int),
}
// The value and everything under it.
Descend :: struct {}
// A JSON Pointer token of digits, which names a member of an object and an element of an array.
Either :: struct {
	name:  string,
	index: int,
}

// A zero `Step` is a `Name` with no data pointer, which a read refuses as `Bad_Path`, so a path built with an unset step
// fails instead of reading an empty key. A name that is empty needs a data pointer, as every parsed one has.
Step :: union #no_nil {
	Name,
	Index,
	All,
	Slice,
	Descend,
	Either,
}

// `optional` holds a bit per step a `?` follows, and `limit` is the most answers the path gives, nil for no limit. `block`
// is the allocation behind a parsed path's steps and its decoded names, nil for a path of step literals. A parsed path
// borrows its text for every name that holds no escape.
Path :: struct {
	steps:     []Step,
	optional:  bit_set[0 ..< MAX_STEPS; u64],
	limit:     Maybe(int),
	block:     []u8,
	allocator: runtime.Allocator,
}

// A read's options. `dups` is nil for `.Last`, or for `.First` under `stop_early`. `refuse_duplicates` faults at a repeated
// key, so the read builds the whole text. `stop_early` ends the walk once every answer is known, and what lies past that
// point is not judged. `every_key` has a `Name` answer every key that matches instead of the one `dups` picks.
Path_Options :: struct {
	dups:              Maybe(Duplicates),
	refuse_duplicates: bool,
	stop_early:        bool,
	every_key:         bool,
}

// What a query over a built document can honour of `Path_Options`: the other fields are the walk's.
Query_Options :: struct {
	dups:      Maybe(Duplicates),
	every_key: bool,
}

Answer_Outcome :: enum u8 {
	Found,
	Missing,
	Type_Mismatch,
}

// What a path gives for one value it reaches. `node` is the value of a `.Found`, `NO_NODE` for the others. `owner` is the
// container holding a `.Found` value, `NO_NODE` for the root, the deepest container reached for a `.Missing`, and for
// a `.Type_Mismatch` the value a step could not enter. A null reads as `.Missing` where jq reads `.a` of it as null, and
// its owner is the container holding it, or the null at the root. A missing member with a `[]` still to come is a
// `.Type_Mismatch` naming the container that lacks it. `path` is the path's number in the read.
Answer :: struct {
	node:    Node_Index,
	owner:   Node_Index,
	path:    u32,
	outcome: Answer_Outcome,
}

// What `each_answer` gives for one value a path reaches, with no document. `token` is the value's for a `.Found` and a
// `.Type_Mismatch`, and the closing token of the container that lacks it, or the null, for a `.Missing`. For a `.Found`,
// `lo` and `hi` are the value's authored span, `src[lo:hi]`, the bytes `span` gives for its node in every format, so a
// string's quotes and a quoted cell's quotes are inside it. For the other outcomes both are 0.
Token_Answer :: struct {
	token:   Token,
	lo, hi:  u64,
	path:    u32,
	outcome: Answer_Outcome,
}

Path_Edit_Error_Kind :: enum u8 {
	None,
	Path, // the read of the path failed, in `path`
	Edit, // the build, the edit or the commit failed, in `edit`
}

// What a path edit can fail with: the read of the path, or the build, the edit and its commit.
Path_Edit_Error :: struct {
	kind: Path_Edit_Error_Kind,
	path: Path_Error,
	edit: Document_Error,
}

// The true position of a child a `Partial` container kept, for a container read by position. `Document.kept` holds these,
// sorted by node.
Kept_Child :: struct {
	node:  Node_Index,
	index: u32,
}

// A name a path asked `node` for and did not find. `Document.missing` holds these, sorted by node, and the names are
// copies in the document's reads block.
Missing_Name :: struct {
	node: Node_Index,
	name: string,
}

// What a read of a member or an element gives. `Wrong_Kind` is a value that cannot take the read, as the path's
// `.Type_Mismatch`: a name of a value that is no map, a position of a value that is no array or positional record. A
// `null` takes both reads and holds nothing. `Not_Loaded` is the answer of a `Partial` container for what a read did not
// ask for: it may or may not be in the text.
Presence :: enum u8 {
	Found,
	Missing,
	Wrong_Kind,
	Not_Loaded,
}

// Reads a member as `member` does, and on a `Partial` container tells a name a path looked for from one nobody asked for.
// A member kept by position was not looked for by name: under `.Last` a repeat of its key may lie among what the read
// did not keep, so it is `Not_Loaded`.
member_of :: proc(doc: ^Document, obj: Node_Index, name: string, dups := Duplicates.Last) -> (Node_Index, Presence) {
	if int(obj) < len(doc.nodes) && doc.nodes[obj].kind != .Map && doc.nodes[obj].kind != .Null {
		return NO_NODE, .Wrong_Kind
	}
	v, ok := member(doc, obj, name, dups)
	partial := int(obj) < len(doc.nodes) && doc.nodes[obj].role == .Partial
	if ok {
		if partial && dups == .Last && kept_index(doc, v) >= 0 {
			return NO_NODE, .Not_Loaded
		}
		return v, .Found
	}
	if !partial {
		return NO_NODE, .Missing
	}
	lo := lower_node(doc.missing, obj)
	for ; lo < len(doc.missing) && doc.missing[lo].node == obj; lo += 1 {
		if doc.missing[lo].name == name {
			return NO_NODE, .Missing
		}
	}
	return NO_NODE, .Not_Loaded
}

// Reads a member by position as `child_at` does, and on a `Partial` container tells a position past the end from a child
// that was not kept. A container a stopped read left open does not know its end. A `Map` answers by position only when
// the format's records are positional, as a dsv record is.
element_of :: proc(doc: ^Document, c: Node_Index, k: int) -> (Node_Index, Presence) {
	if int(c) < len(doc.nodes) {
		kind := doc.nodes[c].kind
		if kind != .Array && kind != .Null && !(kind == .Map && (doc.positional || doc.shared_keys != 0)) {
			return NO_NODE, .Wrong_Kind
		}
	}
	if v, ok := child_at(doc, c, k); ok {
		return v, .Found
	}
	if int(c) < len(doc.nodes) && doc.nodes[c].role == .Partial && k >= 0 && (k < length(doc, c) || doc.stopped) {
		return NO_NODE, .Not_Loaded
	}
	return NO_NODE, .Missing
}

// Returns `length`, and whether it is the container's true count. A `Partial` container of a stopped read holds the
// count read so far.
length_exact :: proc(doc: ^Document, i: Node_Index) -> (n: int, exact: bool) {
	return length(doc, i), !(doc.stopped && int(i) < len(doc.nodes) && doc.nodes[i].role == .Partial)
}

// Returns the child of `Partial` container `i` at true position `k`, when it was kept.
@(private, cold)
kept_child :: #force_no_inline proc(doc: ^Document, i: Node_Index, k: int) -> (Node_Index, bool) {
	it := children(doc, i)
	for {
		v, more := child_next(&it)
		if !more {
			return NO_NODE, false
		}
		if kept_index(doc, v) == k {
			return v, true
		}
	}
}

// Returns the true position `Document.kept` gives child `v`, -1 for a child kept by name.
@(private)
kept_index :: proc(doc: ^Document, v: Node_Index) -> int {
	at := lower_node(doc.kept, v)
	return int(doc.kept[at].index) if at < len(doc.kept) && doc.kept[at].node == v else -1
}

// Frees a parsed path's block and sets `p` to the zero value.
path_destroy :: proc(p: ^Path) {
	if p.block != nil {
		delete(p.block, p.allocator)
	}
	p^ = {}
}

@(private = "file")
Parser :: struct {
	text:     string,
	at:       int,
	n:        int,
	steps:    [MAX_STEPS]Step,
	optional: bit_set[0 ..< MAX_STEPS; u64],
	// The `Name` steps that still hold their source spelling, which `path_of` decodes.
	escaped:  bit_set[0 ..< MAX_STEPS; u64],
	limit:    Maybe(int),
	fault:    Path_Error,
}

@(private = "file")
bad_path :: proc(p: ^Parser, at: int) -> bool {
	p.fault = {kind = .Bad_Path, at = u64(at)}
	return false
}

// Reads jq path text: `.`, `.a`, `."a-b"`, `.["a-b"]`, `.[0]`, `.[-1]`, `.[]`, `.[2:5]`, `..` first in a path, `?` after
// any step, and the wrappers `first(P)` and `limit(N; P)`. A quoted name's escapes are a JSON string's, a lone surrogate
// escape is refused as in one, and its other bytes stand as written. Spaces may stand around the text and inside a
// wrapper, not inside a path. Text past this subset is refused, so a path means here what it means in jq. A bare name is
// a jq identifier. `.Bad_Path`'s `at` is a byte of `text`.
parse_path :: proc(text: string, allocator := context.allocator) -> (path: Path, err: Path_Error) {
	return parse(text, allocator, false)
}

@(private = "file")
parse :: proc(text: string, allocator: runtime.Allocator, $POINTER: bool) -> (Path, Path_Error) {
	p := Parser{text = text}
	if !(parse_tokens(&p) if POINTER else parse_text(&p)) {
		return {}, p.fault
	}
	return path_of(&p, allocator, POINTER)
}

@(private = "file")
parse_text :: proc(p: ^Parser) -> bool {
	skip_spaces(p)
	closes := false
	if eat(p, "first(") {
		p.limit = 1
		closes = true
	} else if eat(p, "limit(") {
		closes = true
		skip_spaces(p)
		lo := p.at
		n, ok := parse_int(p)
		if !ok || n < 0 {
			return bad_path(p, lo)
		}
		p.limit = n
		skip_spaces(p)
		if !eat(p, ";") {
			return bad_path(p, p.at)
		}
	}
	skip_spaces(p)
	parse_chain(p) or_return
	skip_spaces(p)
	if closes {
		if !eat(p, ")") {
			return bad_path(p, p.at)
		}
		skip_spaces(p)
	}
	return p.at == len(p.text) || bad_path(p, p.at)
}

// Reads an RFC 6901 JSON Pointer: the empty text is the root, and each `/` starts a reference token, in which `~0` is `~`
// and `~1` is `/`. A token that is an array index by the RFC's rule, with no leading zero, is an `Either`.
parse_pointer :: proc(text: string, allocator := context.allocator) -> (path: Path, err: Path_Error) {
	return parse(text, allocator, true)
}

@(private = "file")
parse_tokens :: proc(p: ^Parser) -> bool {
	t := p.text
	if len(t) > 0 && t[0] != '/' {
		return bad_path(p, 0)
	}
	for p.at < len(t) {
		lo := p.at + 1
		hi := lo
		tilde := false
		for hi < len(t) && t[hi] != '/' {
			if t[hi] == '~' {
				if hi + 1 == len(t) || t[hi + 1] != '0' && t[hi + 1] != '1' {
					return bad_path(p, hi)
				}
				tilde = true
			}
			hi += 1
		}
		p.at = hi
		token := t[lo:hi]
		if index, ok := pointer_index(token); ok {
			push_step(p, Either{token, index}) or_return
			continue
		}
		push_step(p, Name(token)) or_return
		if tilde {
			p.escaped += {p.n - 1}
		}
	}
	return true
}

// Copies the parser's steps into one block with the names it decodes, as a pointer when `$POINTER`.
@(private = "file")
path_of :: proc(p: ^Parser, allocator: runtime.Allocator, $POINTER: bool) -> (Path, Path_Error) {
	if p.n == 0 {
		return {limit = p.limit}, {}
	}
	head := p.n * size_of(Step)
	size := head
	for i in p.escaped {
		size += len(p.steps[i].(Name))
	}
	block, failed := runtime.mem_alloc_bytes(size, align_of(Step), allocator)
	if failed != nil {
		return {}, {kind = .No_Memory}
	}
	steps := ([^]Step)(raw_data(block))[:p.n]
	copy(steps, p.steps[:p.n])
	w := head
	for i in p.escaped {
		k := decode_pointer(string(p.steps[i].(Name)), block[w:]) if POINTER else decode_quoted(string(p.steps[i].(Name)), block[w:])
		steps[i] = Name(string(block[w:w + k]))
		w += k
	}
	return {steps = steps, optional = p.optional, limit = p.limit, block = block, allocator = allocator}, {}
}

@(private = "file")
skip_spaces :: proc(p: ^Parser) {
	for p.at < len(p.text) && (p.text[p.at] == ' ' || p.text[p.at] == '\t' || p.text[p.at] == '\n' || p.text[p.at] == '\r') {
		p.at += 1
	}
}

@(private = "file")
eat :: proc(p: ^Parser, s: string) -> bool {
	if len(p.text) - p.at >= len(s) && p.text[p.at:p.at + len(s)] == s {
		p.at += len(s)
		return true
	}
	return false
}

@(private = "file")
push_step :: proc(p: ^Parser, s: Step) -> bool {
	if p.n == MAX_STEPS {
		p.fault = {kind = .Over_Capacity}
		return false
	}
	p.steps[p.n] = s
	p.n += 1
	return true
}

// Reads a path from its `.` up to the first byte that continues no step, which the caller judges.
@(private = "file")
parse_chain :: proc(p: ^Parser) -> bool {
	t := p.text
	if p.at == len(t) || t[p.at] != '.' {
		return bad_path(p, p.at)
	}
	if eat(p, "..") {
		push_step(p, Descend{}) or_return
	} else if p.at + 1 == len(t) || !(t[p.at + 1] == '"' || t[p.at + 1] == '[' || is_name_start(t[p.at + 1])) {
		p.at += 1
	}
	for p.at < len(t) {
		switch t[p.at] {
		case '?':
			if p.n > 0 {
				p.optional += {p.n - 1}
			}
			p.at += 1
		case '[':
			parse_bracket(p) or_return
		case '.':
			parse_field(p) or_return
		case:
			return true
		}
	}
	return true
}

@(private = "file")
is_name_start :: proc(b: u8) -> bool {
	return b == '_' || b | 0x20 >= 'a' && b | 0x20 <= 'z'
}

// Reads the step after a `.`: a bare name or a quoted one. A `.` before a `[` is passed over for the next step to read.
@(private = "file")
parse_field :: proc(p: ^Parser) -> bool {
	t := p.text
	if p.at + 1 == len(t) {
		return bad_path(p, p.at)
	}
	b := t[p.at + 1]
	switch {
	case b == '[':
		p.at += 1
		return true
	case b == '"':
		p.at += 1
		return parse_quoted(p)
	case is_name_start(b):
		lo := p.at + 1
		p.at = lo
		for p.at < len(t) && (is_name_start(t[p.at]) || t[p.at] >= '0' && t[p.at] <= '9') {
			p.at += 1
		}
		return push_step(p, Name(t[lo:p.at]))
	}
	return bad_path(p, p.at)
}

// Reads the quoted name at `p.at` as a JSON string. A name with an escape is judged here and decoded in `path_of`.
@(private = "file")
parse_quoted :: proc(p: ^Parser) -> bool {
	t := p.text
	lo := p.at + 1
	i := lo
	escape := false
	for i < len(t) && t[i] != '"' {
		if t[i] == '\\' {
			_, n := quoted_escape(t, i)
			if n == 0 {
				return bad_path(p, i)
			}
			escape = true
			i += n
		} else {
			i += 1
		}
	}
	if i >= len(t) {
		return bad_path(p, p.at)
	}
	raw := t[lo:i]
	push_step(p, Name(raw)) or_return
	if escape {
		p.escaped += {p.n - 1}
	}
	p.at = i + 1
	return true
}

// Reads `[...]`: `[]`, a quoted name, an index or a slice.
@(private = "file")
parse_bracket :: proc(p: ^Parser) -> bool {
	t := p.text
	open := p.at
	p.at += 1
	if eat(p, "]") {
		return push_step(p, All{})
	}
	if p.at < len(t) && t[p.at] == '"' {
		parse_quoted(p) or_return
		return eat(p, "]") || bad_path(p, p.at)
	}
	lo, has_lo := parse_int(p)
	if !eat(p, ":") {
		if !has_lo {
			return bad_path(p, open)
		}
		push_step(p, Index(lo)) or_return
		return eat(p, "]") || bad_path(p, p.at)
	}
	hi, has_hi := parse_int(p)
	if !has_lo && !has_hi {
		return bad_path(p, open)
	}
	s := Slice{lo = lo if has_lo else 0, hi = hi if has_hi else nil}
	push_step(p, s) or_return
	return eat(p, "]") || bad_path(p, p.at)
}

// Reads the digits at `t[i:]` as an `int`, returning the byte past them, and false when there is none or it overflows.
@(private = "file")
digits_int :: proc(t: string, i: int) -> (value: int, end: int, ok: bool) {
	end = i
	for end < len(t) && t[end] >= '0' && t[end] <= '9' {
		d := int(t[end] - '0')
		if value > (max(int) - d) / 10 {
			return 0, i, false
		}
		value = value * 10 + d
		end += 1
	}
	return value, end, end > i
}

// Reads an optional `-` and its digits, and leaves `p.at` where it was when they make no `int`.
@(private = "file")
parse_int :: proc(p: ^Parser) -> (value: int, ok: bool) {
	i := p.at
	minus := i < len(p.text) && p.text[i] == '-'
	n, end, good := digits_int(p.text, i + 1 if minus else i)
	if !good {
		return 0, false
	}
	p.at = end
	return -n if minus else n, true
}

// Decodes the escape at `raw[i]` and returns its rune and length, 0 for a bad one.
@(private = "file")
quoted_escape :: proc(raw: string, i: int) -> (r: rune, n: int) {
	if i + 1 >= len(raw) {
		return 0, 0
	}
	switch raw[i + 1] {
	case '"', '\\', '/':
		return rune(raw[i + 1]), 2
	case 'b':
		return '\b', 2
	case 'f':
		return '\f', 2
	case 'n':
		return '\n', 2
	case 'r':
		return '\r', 2
	case 't':
		return '\t', 2
	case 'u':
		if len(raw) - i < 6 {
			return 0, 0
		}
		unit, ok := spell.hex4(raw_data(raw)[i + 2:])
		if !ok || spell.low_surrogate(unit) {
			return 0, 0
		}
		if !spell.high_surrogate(unit) {
			return rune(unit), 6
		}
		if len(raw) - i < 12 || raw[i + 6] != '\\' || raw[i + 7] != 'u' {
			return 0, 0
		}
		low, low_ok := spell.hex4(raw_data(raw)[i + 8:])
		if !low_ok || !spell.low_surrogate(low) {
			return 0, 0
		}
		return 0x10000 + rune(unit - 0xD800) << 10 + rune(low - 0xDC00), 12
	}
	return 0, 0
}

// Decodes a judged quoted name into `out`, which holds `len(raw)` bytes, as no escape grows. Returns the bytes written.
@(private = "file")
decode_quoted :: proc(raw: string, out: []u8) -> int {
	w := 0
	for i := 0; i < len(raw); {
		if raw[i] != '\\' {
			out[w] = raw[i]
			w += 1
			i += 1
			continue
		}
		r, n := quoted_escape(raw, i)
		bytes, size := utf8.encode_rune(r)
		copy(out[w:], bytes[:size])
		w += size
		i += n
	}
	return w
}

// Decodes a judged pointer token into `out`, which holds `len(raw)` bytes. Returns the bytes written.
@(private = "file")
decode_pointer :: proc(raw: string, out: []u8) -> int {
	w := 0
	for i := 0; i < len(raw); i += 1 {
		b := raw[i]
		if b == '~' {
			i += 1
			b = '/' if raw[i] == '1' else '~'
		}
		out[w] = b
		w += 1
	}
	return w
}

// Returns the array index `token` spells: `0`, or digits with no leading zero, that fit an `int`.
@(private = "file")
pointer_index :: proc(token: string) -> (index: int, ok: bool) {
	if len(token) == 0 || len(token) > 1 && token[0] == '0' {
		return 0, false
	}
	n, end, good := digits_int(token, 0)
	return n, good && end == len(token)
}
