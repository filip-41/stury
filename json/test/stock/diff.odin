package stock

// A strict-DOM differential against `core:encoding/json` on the installed
// toolchain, called as `Specification.JSON` with `parse_integers = false`.
//
// Both parsers run on every document stock can take without overflowing its
// stack. Each disagreement lands in one closed class, and only `.Mismatch` is a
// defect.

import json "../.."
import sj "core:encoding/json"
import "core:math"
import "core:mem"
import "core:unicode/utf8"

Class :: enum {
	Agree,       // both accept, and every value matches
	Both_Reject,
	Budget,      // stury hit a digit, scale or depth cap that stock does not have
	Stock_Lax,   // stury rejects a listed byte stock's JSON mode lets through
	Duplicate,   // stury accepts, stock refuses a repeated key (values unchecked)
	Rounding,    // both accept, and some number is one ULP apart
	Mismatch,    // a defect on one side
	Skipped,     // stock was not called, stury ran as a crash oracle only
}

Diff :: struct {
	class:     Class,
	stury_err: Maybe(json.Error),
	stock_err: sj.Error,
	// The first disagreement, for `.Mismatch` only.
	detail:    string,
}

// Deepest nesting stock is handed. Its parser recurses once per level on an
// `odin test` worker thread, so this is a stack bound. Stury's own cap is the
// largest depth both sides accept, so past it a document is a crash oracle only.
STOCK_MAX_DEPTH :: 1024
STOCK_MAX_BYTES :: 65536

// Stock's `unquote_string` sizes its buffer at `len(s) + 8` and writes the
// 3-byte U+FFFD for each invalid byte, so five invalid bytes in one string
// index past it and panic (`"\xff\xff\xff\xff\xff"` alone, dev-2026-09).
STOCK_MAX_INVALID_UTF8 :: 4

// Run both parsers on `src` and classify the outcome. Stury allocates from
// `allocator` and frees before returning, so a tracking allocator still sees its
// leaks. Stock runs in a private arena dropped whole: it leaks the partial value
// of every document it rejects, and frees through `context.allocator` whatever
// allocator it was handed.
diff_document :: proc(src: []byte, allocator := context.allocator) -> Diff {
	doc, stury_err := json.build(src, allocator)
	defer json.destroy(&doc)
	d := Diff{stury_err = stury_err}
	depth, _ := scan_structure(src)
	if len(src) > STOCK_MAX_BYTES || depth > STOCK_MAX_DEPTH || invalid_utf8_bytes(src) > STOCK_MAX_INVALID_UTF8 {
		d.class = .Skipped
		return d
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)

	p := sj.make_parser(src, .JSON, false, context.allocator)
	stock_val, stock_err := sj.parse_value(&p)
	if stock_err == nil && p.curr_token.kind != .EOF {
		stock_err = .Unexpected_Token
	}
	d.stock_err = stock_err

	fault, stury_rejected := stury_err.?
	switch {
	case stury_rejected && stock_err != nil:
		d.class = .Both_Reject
	case stury_rejected && is_budget(fault.kind):
		d.class = .Budget
	case stury_rejected && is_stock_lax(src, fault):
		d.class = .Stock_Lax
	case stury_rejected:
		d.class, d.detail = .Mismatch, "stury rejects a document stock accepts"
	case stock_err == .Duplicate_Object_Key:
		d.class = .Duplicate
	case stock_err != nil:
		d.class, d.detail = .Mismatch, "stury accepts a document stock rejects"
	case:
		w := Walk{doc = &doc}
		walk_value(&w, json.ROOT, stock_val)
		switch {
		case w.detail != "":
			d.class, d.detail = .Mismatch, w.detail
		case w.rounded:
			d.class = .Rounding
		case:
			d.class = .Agree
		}
	}
	return d
}

is_budget :: proc(k: json.Error_Kind) -> bool {
	return k == .Limit_Digits || k == .Limit_Scale || k == .Too_Deep
}

// Rejections stock's JSON mode does not share, each read off its tokenizer and
// parser source: `\v` and `\f` are whitespace, a raw NUL ends the input, a
// string takes raw control bytes and invalid UTF-8 unchecked, and `parse_comma`
// lets a comma sit before the closing bracket. `advance_token` returns the
// tokenizer's error and every caller drops it, so a malformed number, a bad
// escape (`unquote_string` stops there with no error) and an unterminated
// string all parse.
//
// Each rule re-reads the bytes, so a stury refusal of valid input is still a
// `.Mismatch`: a byte >= 0x80 counts only when no rune decodes at it, a number
// only when it is not RFC 8259's grammar.
is_stock_lax :: proc(src: []byte, e: json.Error) -> bool {
	if e.kind == .Truncated {
		_, open_string := scan_structure(src)
		return open_string || is_bad_number_at(src, len(src))
	}
	if e.offset >= u64(len(src)) {
		return false
	}
	at := src[e.offset]
	switch e.kind {
	case .Bad_Char, .Trailing:
		if at < 0x20 {
			return true
		}
		if at >= 0x80 {
			r, _ := utf8.decode_rune(src[e.offset:])
			return r == utf8.RUNE_ERROR
		}
		return (at == ']' || at == '}') && prev_significant(src, e.offset) == ','
	case .Bad_Number:
		return is_bad_number_at(src, int(e.offset))
	case .Bad_Escape:
		return is_bad_escape_at(src, int(e.offset)) || is_lone_surrogate_at(src, int(e.offset))
	case .None, .Truncated, .Bad_Literal, .Limit_Digits, .Limit_Scale, .Too_Deep, .Source_Too_Wide, .Out_Of_Memory, .Duplicate_Key, .Bad_Option:
	}
	return false
}

prev_significant :: proc(src: []byte, before: u64) -> byte {
	for i := int(before) - 1; i >= 0; i -= 1 {
		switch src[i] {
		case ' ', '\t', '\n', '\r':
		case:
			return src[i]
		}
	}
	return 0
}

// A run of number bytes touches `off` and is not RFC 8259's grammar.
is_bad_number_at :: proc(src: []byte, off: int) -> bool {
	tok := number_token(src, off)
	return len(tok) > 0 && !is_json_number(tok)
}

// The run of number bytes around `off` (empty when there is none).
number_token :: proc(src: []byte, off: int) -> []byte {
	lo, hi := off, off
	for lo > 0 && is_number_byte(src[lo - 1]) {
		lo -= 1
	}
	for hi < len(src) && is_number_byte(src[hi]) {
		hi += 1
	}
	return src[lo:hi]
}

// RFC 8259: -? (0 | [1-9]\d*) (\.\d+)? ([eE][+-]?\d+)?
is_json_number :: proc(tok: []byte) -> bool {
	i := 0
	digits :: proc(tok: []byte, i: ^int) -> (n: int) {
		for i^ < len(tok) && tok[i^] >= '0' && tok[i^] <= '9' {
			i^ += 1
			n += 1
		}
		return
	}
	if i < len(tok) && tok[i] == '-' {
		i += 1
	}
	lead := i
	if digits(tok, &i) == 0 || (tok[lead] == '0' && i - lead > 1) {
		return false
	}
	if i < len(tok) && tok[i] == '.' {
		i += 1
		if digits(tok, &i) == 0 {
			return false
		}
	}
	if i < len(tok) && (tok[i] == 'e' || tok[i] == 'E') {
		i += 1
		if i < len(tok) && (tok[i] == '+' || tok[i] == '-') {
			i += 1
		}
		if digits(tok, &i) == 0 {
			return false
		}
	}
	return i == len(tok)
}

// Whether the byte at `off` is where an escape goes wrong: an unescaped `\`
// followed by a byte that is no escape, or `\u` with fewer than four hex
// digits before `off`.
is_bad_escape_at :: proc(src: []byte, off: int) -> bool {
	// The nearest backslash before `off`, at most `\uXXX` back.
	for back in 1 ..= 5 {
		bs := off - back
		if bs < 0 || src[bs] != '\\' {
			continue
		}
		run := 0
		for bs - run >= 0 && src[bs - run] == '\\' {
			run += 1
		}
		if run % 2 == 0 {
			continue
		}
		if back == 1 {
			switch src[off] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u':
				return false
			}
			return true
		}
		if src[bs + 1] != 'u' {
			return false
		}
		for b in src[bs + 2:off] {
			if _, ok := hex_value(b); !ok {
				return false
			}
		}
		_, ok := hex_value(src[off])
		return !ok
	}
	return false
}

// A `\uD800`-`\uDFFF` escape at `off` that no pair completes: stock decodes it to U+FFFD.
is_lone_surrogate_at :: proc(src: []byte, off: int) -> bool {
	unit, ok := escape_unit_at(src, off)
	if !ok || unit < 0xD800 || unit > 0xDFFF {
		return false
	}
	low, paired := escape_unit_at(src, off + 6)
	return unit >= 0xDC00 || !paired || low < 0xDC00 || low > 0xDFFF
}

// The code unit that `\uXXXX` at `off` encodes, if one is there.
escape_unit_at :: proc(src: []byte, off: int) -> (unit: u32, ok: bool) {
	if off + 6 > len(src) || src[off] != '\\' || src[off + 1] != 'u' {
		return 0, false
	}
	for b in src[off + 2:off + 6] {
		d := hex_value(b) or_return
		unit = unit << 4 | d
	}
	return unit, true
}

hex_value :: proc(b: byte) -> (value: u32, ok: bool) {
	switch b {
	case '0' ..= '9': return u32(b - '0'), true
	case 'a' ..= 'f': return u32(b - 'a' + 10), true
	case 'A' ..= 'F': return u32(b - 'A' + 10), true
	}
	return 0, false
}

invalid_utf8_bytes :: proc(src: []byte) -> (n: int) {
	for rest := src; len(rest) > 0; {
		r, w := utf8.decode_rune(rest)
		if r == utf8.RUNE_ERROR && w == 1 {
			n += 1
		}
		rest = rest[w:]
	}
	return
}

is_number_byte :: proc(b: byte) -> bool {
	switch b {
	case '0' ..= '9', '-', '+', '.', 'e', 'E':
		return true
	}
	return false
}

// The deepest bracket nesting outside strings, and whether the input ends inside an open string. Malformed
// input still gets an answer: an unterminated string ends the count, an excess close is ignored.
scan_structure :: proc(src: []byte) -> (deepest: int, ends_in_string: bool) {
	depth := 0
	esc := false
	for b in src {
		switch {
		case ends_in_string && esc:
			esc = false
		case ends_in_string && b == '\\':
			esc = true
		case ends_in_string && b == '"':
			ends_in_string = false
		case ends_in_string:
		case b == '"':
			ends_in_string = true
		case b == '[' || b == '{':
			depth += 1
			deepest = max(deepest, depth)
		case b == ']' || b == '}':
			depth = max(depth - 1, 0)
		}
	}
	return
}

Walk :: struct {
	doc:     ^json.Document,
	rounded: bool,
	detail:  string,
}

// Compares row `i` and its subtree against `v`, stopping at the first
// disagreement. Objects are matched by key lookup, never by ranging the map:
// stock seeds its hash with the map's address, so iteration order varies.
walk_value :: proc(w: ^Walk, i: json.Node, v: sj.Value) {
	if w.detail != "" {
		return
	}
	k, _ := json.kind(w.doc, i)
	switch k {
	case .Object:
		obj, ok := v.(sj.Object)
		if !ok {
			w.detail = "object against a non-object"
			return
		}
		keyed := 0
		kv := json.members(w.doc, i)
		for key, j in json.members(&kv) {
			// Stock parses an empty-keyed member and then drops it.
			if len(key) == 0 {
				continue
			}
			keyed += 1
			elem, found := obj[string(key)]
			if !found {
				w.detail = "member key absent from stock"
				return
			}
			walk_value(w, j, elem)
			if w.detail != "" {
				return
			}
		}
		if kv.node < kv.end {
			w.detail = "member key does not decode"
		} else if keyed != len(obj) {
			w.detail = "member count differs"
		}
	case .Array:
		arr, ok := v.(sj.Array)
		if !ok {
			w.detail = "array against a non-array"
			return
		}
		if json.child_count(w.doc, i) != len(arr) {
			w.detail = "element count differs"
			return
		}
		n := 0
		it := json.children(w.doc, i)
		for j in json.children(&it) {
			walk_value(w, j, arr[n])
			n += 1
		}
	case .Number:
		f, ok := v.(sj.Float)
		if !ok {
			w.detail = "number against a non-float"
			return
		}
		compare_number(w, i, f64(f))
	case .String:
		s, ok := v.(sj.String)
		mine, mine_ok := json.get_string(w.doc, i)
		if !ok || !mine_ok || mine != string(s) {
			w.detail = "string differs"
		}
	case .True, .False:
		b, ok := v.(sj.Boolean)
		if !ok || bool(b) != (k == .True) {
			w.detail = "boolean differs"
		}
	case .Null:
		if _, ok := v.(sj.Null); !ok {
			w.detail = "null against a non-null"
		}
	}
}

// `.None` is stury's overflow arm, its zero is not the value, and stock's
// answer there is an infinity. Otherwise the bits must match, or sit one ULP
// apart: installed `strconv.parse_f64` misrounds cases the private scan suite
// pins. Bits, not `==`, so `-0` is not `+0`.
compare_number :: proc(w: ^Walk, i: json.Node, stock: f64) {
	number, _ := json.get_number(w.doc, i)
	mine := number.value
	if number.exactness == .None {
		if !math.is_inf(stock) && !math.is_nan(stock) {
			w.detail = "stury refused a number stock reads as finite"
		}
		return
	}
	a, b := transmute(u64)mine, transmute(u64)stock
	switch {
	case a == b:
	case math.is_inf(stock) || math.is_nan(stock):
		w.detail = "stock non-finite where stury is finite"
	case a >> 63 == b >> 63 && (a - b == 1 || b - a == 1):
		w.rounded = true
	case:
		w.detail = "number differs"
	}
}
