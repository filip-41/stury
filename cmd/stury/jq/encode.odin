package jq

// Values printed as jq 1.8 prints them: its number formats, its string escapes, its layout.

import "base:intrinsics"
import "core:bytes"
import "core:math"
import "core:simd"
import json "../../../json"
import enc "../../../json/encode"

Layout :: struct {
	pretty:        bool,
	indent:        int, // spaces per level; -1 is a tab
	sort_keys:     bool,
	ascii:         bool,
	colors:        ^[8]string, // jq's colours in jq's order (null, false, true, numbers, strings, arrays, objects, keys); nil for none
	comments:      ^enc.Comment_Layout, // a JSONC document's comments, printed at their attachment points (`write_answer`); nil for none
	drop_comments: bool, // `write_answer` prints no comments even when the value has some (output other than JSONC)
	spill:         ^Spill, // receives the output once it reaches `at` bytes, so a deep value is not held whole; nil for none
}

// A layout's way to empty the output it is written into, the dynamic array `write_value` is given.
Spill :: struct {
	at:    int,
	flush: proc(data: rawptr),
	data:  rawptr,
}

// The output written so far, spilled when the layout has a place for it and it has passed its size.
@(private = "file")
spill :: #force_inline proc(out: ^[dynamic]byte, l: Layout) {
	if l.spill != nil && len(out) >= l.spill.at {
		l.spill.flush(l.spill.data)
	}
}

// `v` laid out `depth` levels in. In colour, as jq's jv_dump_term paints it: each value in its kind's colour, reset
// after. A container's punctuation in its colour, reset before each member, and an object's keys in theirs. A NaN is
// a number painting a null.
write_value :: proc(out: ^[dynamic]byte, v: Value, l: Layout, depth := 0) {
	k := kind(v)
	if l.colors != nil {
		paint(out, l, int(k))
		if k == .Number {
			if n, _ := number_of(v); n.lit == "" && math.is_nan(n.f) {
				write_value(out, nil, l, depth)
				unpaint(out, l)
				return
			}
		}
	}
	switch {
	case depth > MAX_DEPTH:
		append(out, "<skipped: too deep>") // what jq prints past its depth limit
	case k == .Null:
		append(out, "null")
	case k == .False:
		append(out, "false")
	case k == .True:
		append(out, "true")
	case k == .Number:
		if r, is_ref := v.(Ref); is_ref {
			enc.put_jq_literal(out, string(json.get_raw(r.doc, r.node)))
			break
		}
		n, _ := number_of(v)
		if n.lit != "" {
			enc.put_jq_literal(out, n.lit)
		} else {
			enc.put_jq_double(out, n.f)
		}
	case k == .String:
		s, _ := string_of(v)
		write_string(out, s, l.ascii)
	case is_empty(v):
		append(out, '[' if k == .Array else '{')
		if l.comments != nil {
			if wrote, _ := enc.put_feet(out, l.comments, comments_of(v, l), depth); wrote {
				newline(out, l, depth)
			}
		}
		append(out, ']' if k == .Array else '}')
	case k == .Array:
		append(out, '[')
		unpaint(out, l)
		newline(out, l, depth + 1)
		write_items(out, v, l, depth)
		if l.comments != nil {
			enc.put_feet(out, l.comments, comments_of(v, l), depth)
		}
		spill(out, l)
		newline(out, l, depth)
		paint(out, l, int(k))
		append(out, ']')
	case:
		append(out, '{')
		first := true
		last: []json.Fact // the member written last's comments, whose trailing ones follow its comma
		if l.sort_keys && is_wide(v) {
			for m in sorted_members(v) {
				write_member(out, m.key, m.val, l, depth, &first, &last)
			}
		} else if l.sort_keys {
			for key in sorted_keys(v) {
				m, _ := object_get(v, key)
				write_member(out, key, m, l, depth, &first, &last)
			}
		} else {
			it := iterate(v)
			for key, m in next_member(&it) {
				write_member(out, key, m, l, depth, &first, &last)
			}
		}
		if l.comments != nil {
			enc.put_trails(out, l.comments, last, depth + 1)
			enc.put_feet(out, l.comments, comments_of(v, l), depth)
		}
		spill(out, l)
		newline(out, l, depth)
		paint(out, l, int(k))
		append(out, '}')
	}
	unpaint(out, l)
}

// The layout's colour `k`, in its order, when it has colours.
@(private = "file")
paint :: #force_inline proc(out: ^[dynamic]byte, l: Layout, k: int) {
	if l.colors != nil {
		append(out, l.colors[k])
	}
}

// The punctuation `c` of a container of kind `k`, painted in its colour when the layout has colours.
write_punct :: proc(out: ^[dynamic]byte, l: Layout, k: Kind, c: byte) {
	paint(out, l, int(k))
	append(out, c)
	unpaint(out, l)
}

// The reset after a colour, when the layout has colours.
@(private = "file")
unpaint :: #force_inline proc(out: ^[dynamic]byte, l: Layout) {
	if l.colors != nil {
		append(out, "\e[0m")
	}
}

// The entries of array `v`, `depth` levels in, as `write_value` lays them out after the line break that
// follows its `[`.
write_items :: proc(out: ^[dynamic]byte, v: Value, l: Layout, depth: int) {
	it := iterate(v)
	first := true
	last: []json.Fact
	for _, m in next_member(&it) {
		if !first {
			write_punct(out, l, .Array, ',')
			if l.comments != nil {
				enc.put_trails(out, l.comments, last, depth + 1)
			}
			newline(out, l, depth + 1)
		}
		first = false
		spill(out, l)
		if l.comments != nil {
			last = comments_of(m, l)
			enc.put_leads(out, l.comments, last, depth + 1)
		}
		write_value(out, m, l, depth + 1)
	}
	if l.comments != nil {
		enc.put_trails(out, l.comments, last, depth + 1)
	}
}

// `v` as `write_value` prints it. A string or container read from JSON text that is already in jq's format is copied,
// or laid out, from that text rather than walked. A value of a JSONC document with comments is printed with each
// comment attached to it or to a value in it, as `json.marshal` places them. A value the filter made has none. A
// caller whose `write_spelled` just refused the text passes no `respell`.
write_answer :: proc(out: ^[dynamic]byte, v: Value, l: Layout, respell := true) {
	r, is_ref := v.(Ref)
	// Only a JSONC document has facts.
	if is_ref && !l.drop_comments && len(r.doc.facts) > 0 {
		own := facts_of(r)
		kd, _ := json.kind(r.doc, r.node)
		if len(own) > 0 || kd >= .Array {
			cl := enc.Comment_Layout{src = r.doc.src, pretty = l.pretty, indent = indent_of(l), ascii = l.ascii}
			l := l
			l.comments = &cl
			enc.put_leads(out, &cl, own, 0, root = true)
			write_value(out, v, l)
			enc.put_trails(out, &cl, own, 0, root = true)
			return
		}
	}
	if !is_ref || l.ascii || l.sort_keys || l.colors != nil {
		write_value(out, v, l)
		return
	}
	text := json.get_raw(r.doc, r.node)
	#partial switch kd, _ := json.kind(r.doc, r.node); kd {
	case .String:
		// JSONC's strings are JSON's.
		if !escaped(text) {
			append(out, ..text)
			return
		}
	case .Object, .Array:
		if respell && r.doc.dialect == .Json && write_spelled(out, text, l) {
			return
		}
	}
	write_value(out, v, l)
}

// The well-formed JSON text of an array or object laid out onto `out` as `write_value` lays out the value it reads
// as, when that is its own format with only the whitespace changed, else it returns false with `out` as it was
// (always so for a layout with colours, which this paints none of). With `items`, `text` is the entries of an array
// at `depth`, without its brackets, laid out as that array lays them out.
write_spelled :: proc(out: ^[dynamic]byte, text: []byte, l: Layout, depth := 0, items := false) -> bool {
	if l.colors != nil {
		return false
	}
	numbers := may_respell(text)
	if numbers && escaped(text) {
		return false
	}
	mark := len(out)
	if spelled_walk(text, numbers, out, l, depth, items) {
		return true
	}
	resize(out, mark)
	return false
}

// Whether `text` has an escape or a DEL, which jq may write differently. One without them is copied as it is.
escaped :: proc(text: []byte) -> bool {
	return bytes.index_byte(text, '\\') >= 0 || bytes.index_byte(text, 0x7f) >= 0
}

// The deepest nesting, and the most keys open at once, `spelled_walk` follows.
@(private = "file")
SPELLED_DEPTH :: 64
@(private = "file")
SPELLED_KEYS :: 128

// Whether JSON text with no escape has no object that repeats a key nor, when `numbers`, a number
// `enc.put_jq_literal` rewrites. Text past what this follows answers no. The text is laid out onto `out` as
// `write_value` lays out the value it reads as, only its whitespace changed, as far as the walk got, `base` levels
// in, with `items`, the text is the entries of an array `base` levels in. Each key is compared with its object's
// earlier ones, and objects past SPELLED_KEYS answer no (jq then respells them).
@(private = "file")
spelled_walk :: proc(text: []byte, numbers: bool, out: ^[dynamic]byte, l: Layout, base: int, items: bool) -> bool #no_bounds_check {
	// Where each open container's keys start in `keys`, -1 for an array.
	opened: [SPELLED_DEPTH]int = ---
	keys: [SPELLED_KEYS]string = ---
	depth, n := 0, 0
	if items {
		opened[0], depth = -1, 1
	}
	key_next := false
	for i := 0; i < len(text); i += 1 {
		switch c := text[i]; c {
		case ' ', '\t', '\n', '\r':
		case '"':
			// With no escape, the next quote ends the string.
			end := i + 1 + bytes.index_byte(text[i + 1:], '"')
			if key_next {
				key := string(text[i + 1:end])
				for k in keys[opened[depth - 1]:n] {
					if len(k) == len(key) && k == key {
						return false
					}
				}
				if n == SPELLED_KEYS {
					return false
				}
				keys[n] = key
				n += 1
				key_next = false
			}
			append(out, ..text[i:end + 1])
			i = end
		case '{', '[':
			if depth == SPELLED_DEPTH {
				return false
			}
			j := i + 1
			for is_space(text[j]) {
				j += 1
			}
			if text[j] == '}' || text[j] == ']' {
				append(out, c, text[j])
				i = j
				break
			}
			append(out, c)
			newline(out, l, base + depth + 1)
			key_next = c == '{'
			opened[depth] = n if key_next else -1
			depth += 1
		case '}', ']':
			depth -= 1
			if opened[depth] >= 0 {
				n = opened[depth]
			}
			newline(out, l, base + depth)
			append(out, c)
		case ',':
			key_next = opened[depth - 1] >= 0
			append(out, ',')
			newline(out, l, base + depth)
		case ':':
			append(out, ':')
			if l.pretty {
				append(out, ' ')
			}
		case:
			// A number or literal, up to the byte that ends it.
			end := i + 1
			for end < len(text) && !is_space(text[end]) && text[end] != ',' && text[end] != '}' && text[end] != ']' {
				end += 1
			}
			if numbers && c != 't' && c != 'f' && c != 'n' && !enc.plain_literal(string(text[i:end])) {
				return false
			}
			append(out, ..text[i:end])
			i = end - 1
		}
	}
	return true
}

@(private = "file")
write_member :: proc(out: ^[dynamic]byte, k: string, m: Value, l: Layout, depth: int, first: ^bool, last: ^[]json.Fact) {
	if !first^ {
		paint(out, l, int(Kind.Object))
		append(out, ',')
	}
	unpaint(out, l)
	if l.comments != nil && !first^ {
		enc.put_trails(out, l.comments, last^, depth + 1)
	}
	first^ = false
	spill(out, l)
	newline(out, l, depth + 1)
	if l.comments != nil {
		last^ = comments_of(m, l)
		enc.put_leads(out, l.comments, last^, depth + 1)
	}
	paint(out, l, 7)
	write_string(out, k, l.ascii)
	unpaint(out, l)
	paint(out, l, int(Kind.Object))
	append(out, ':')
	unpaint(out, l)
	if l.pretty {
		append(out, ' ')
	}
	if l.comments != nil {
		enc.put_inlines(out, l.comments, last^, depth + 1)
	}
	write_value(out, m, l, depth + 1)
}

// The comments attached to a value of a JSONC document, spans of `l.comments.src`. It is none for any other value, or
// when the layout prints none.
@(private = "file")
comments_of :: proc(v: Value, l: Layout) -> []json.Fact {
	r, is_ref := v.(Ref)
	if l.comments == nil || !is_ref {
		return nil
	}
	return facts_of(r)
}

// The layout's indent as the library's printer takes it: a tab, or `l.indent` spaces (none at 0).
@(private = "file")
indent_of :: proc(l: Layout) -> enc.Indent {
	if l.indent < 0 {
		return enc.indent_of({})
	}
	if l.indent == 0 {
		return {head = {0 = '\n'}}
	}
	return enc.indent_of({indent = u8(l.indent)})
}

// Where the last `facts_of` ended. Outputs mostly come in source order, so this is only a hint, checked before use.
@(private = "file", thread_local)
facts_hint: int

// `json.facts` of `r`, found from `facts_hint` on by doubling steps, then halving.
facts_of :: proc(r: Ref) -> []json.Fact {
	all := r.doc.facts[:]
	n := r.node
	lo := facts_hint
	if lo > len(all) || lo > 0 && all[lo - 1].node >= n {
		lo = 0
	}
	// all[lo - 1] is before n's facts, so the first of them is at lo or after.
	for step := 1; lo < len(all) && all[lo].node < n; step *= 2 {
		next := lo + step
		if next < len(all) && all[next].node < n {
			lo = next
			continue
		}
		hi := min(next, len(all))
		lo += 1
		for lo < hi {
			mid := lo + (hi - lo) / 2
			if all[mid].node < n {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		break
	}
	hi := lo
	for hi < len(all) && all[hi].node == n {
		hi += 1
	}
	facts_hint = hi
	return all[lo:hi]
}

// The line break before a member `depth` levels in: none when compact.
newline :: proc(out: ^[dynamic]byte, l: Layout, depth: int) {
	if !l.pretty {
		return
	}
	SPACES :: "\n                                                                "
	TABS :: "\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t"
	pad, n := SPACES, depth * l.indent
	if l.indent < 0 {
		pad, n = TABS, depth
	}
	// The pad's newline goes with its first run.
	k := min(n, len(pad) - 1)
	append(out, pad[:k + 1])
	for n -= k; n > 0; n -= k {
		k = min(n, len(pad) - 1)
		append(out, pad[1:k + 1])
	}
}

// `s` as jq prints a string: JSON's escapes and DEL's, and with `ascii` every character past U+007F as `\u` escapes.
// A jq string is UTF-8, as jq makes each string it reads or builds. One that is not prints as `valid_utf8` makes it.
write_string :: proc(out: ^[dynamic]byte, s: string, ascii := false) {
	mark := len(out)
	if enc.put_string_escaping_del(out, s) == .Bad_Utf8 {
		enc.put_string_escaping_del(out, valid_utf8(s))
	}
	if ascii {
		enc.reescape_tail(out, mark, enc.reescape_of({ascii_only = true}))
	}
}

// Whether `text` has a byte `spelled_walk` must look at: a backslash or DEL, an `e` or `E` after a digit and
// before a byte from `+` to `9` (a sign or digit), or a `.` between zeros, one of which every number
// `enc.plain_literal` refuses has. Strings may hold false alarms.
@(private = "file")
may_respell :: proc(text: []byte) -> bool #no_bounds_check {
	n := len(text)
	// A JSON text's first and last bytes are none of these, so a last block may overlap the one before.
	if n < 18 {
		for i in 1 ..< n - 1 {
			c, prev, next := text[i], text[i - 1], text[i + 1]
			if c == '\\' || c == 0x7f || c | 0x20 == 'e' && prev - '0' < 10 && next - '+' < 15 || c == '.' && prev == '0' && next == '0' {
				return true
			}
		}
		return false
	}
	i := 1
	for ; i + 65 <= n; i += 64 {
		if simd.reduce_or(odd_lanes(text, i) | odd_lanes(text, i + 16) | odd_lanes(text, i + 32) | odd_lanes(text, i + 48)) != 0 {
			return true
		}
	}
	for ; i + 17 <= n; i += 16 {
		if simd.reduce_or(odd_lanes(text, i)) != 0 {
			return true
		}
	}
	return simd.reduce_or(odd_lanes(text, n - 17)) != 0
}

// The lanes of the 16 bytes at `i` that `may_respell` looks for. `text` has a byte before them and after.
@(private = "file")
odd_lanes :: #force_inline proc "contextless" (text: []byte, i: int) -> #simd[16]u8 #no_bounds_check {
	V :: #simd[16]u8
	v := intrinsics.unaligned_load((^V)(&text[i]))
	prev := intrinsics.unaligned_load((^V)(&text[i - 1]))
	next := intrinsics.unaligned_load((^V)(&text[i + 1]))
	odd := simd.lanes_eq(v, V('\\')) | simd.lanes_eq(v, V(0x7f))
	odd |= simd.lanes_eq(v | V(0x20), V('e')) & simd.lanes_lt(prev - V('0'), V(10)) & simd.lanes_lt(next - V('+'), V(15))
	return odd | simd.lanes_eq(v, V('.')) & simd.lanes_eq(prev, V('0')) & simd.lanes_eq(next, V('0'))
}

// The text `tostring` and string interpolation give a value: a string as itself, anything else as
// compact JSON.
text_of :: proc(v: Value) -> string {
	if s, is_str := string_of(v); is_str {
		return s
	}
	return to_json(v)
}

to_json :: proc(v: Value) -> string {
	out := make([dynamic]byte)
	write_value(&out, v, {})
	return string(out[:])
}
