package query

import "base:runtime"
import "core:unicode/utf8"
import "stury:lib/core/tape"

// Strings: UTF-8 bytes, read as bytes, code points or grapheme clusters as the caller asks. A string a document holds
// with no escape is read in place; one with an escape is decoded when it is read out of its container.

is_text :: #force_inline proc "contextless" (v: Value) -> bool {
	if v.kind == .String {
		return true
	}
	return v.kind == .Node && node_is_text(node_token(v))
}

@(private)
node_is_text :: #force_inline proc "contextless" (t: tape.Node) -> bool {
	return t.kind == .String || t.kind == .Plain || t.kind == .Bytes
}

// The bytes of string `v`, which live as long as `v`.
text_of :: #force_inline proc "contextless" (v: Value) -> string {
	if v.kind == .String {
		return string(v.s[:v.n])
	}
	return string(node_bytes(v))
}

// The token of node value `v`. Read where the node is in hand: the reader that gave it reached it.
node_token :: #force_inline proc "contextless" (v: Value) -> tape.Node #no_bounds_check {
	d := (^Doc_Block)(v.p)
	return d.doc.nodes[v.n]
}

// The bytes of scalar node `v` in its text: a number's literal, a string's text when it holds no escape.
node_bytes :: #force_inline proc "contextless" (v: Value) -> []u8 {
	d := (^Doc_Block)(v.p)
	t := node_token(v)
	return tape.span_bytes(&d.doc, t.lo, t.n)
}

// A string of `n` bytes the caller fills at the pointer returned, in a block of at least `room` bytes.
@(require_results)
make_text :: proc(h: ^Heap, n: int, room := 0) -> (Value, [^]u8, Status) {
	if u64(n) > u64(max(u32)) {
		return NULL, nil, fail(h, .Range, .To_Text)
	}
	size := block_room(size_of(Str_Block) + max(n, room))
	b, s := alloc_block(h, size)
	if s != .Ok {
		return NULL, nil, s
	}
	x := (^Str_Block)(b)
	x.cap = u32(size - size_of(Str_Block))
	bytes := ([^]u8)(uintptr(x) + size_of(Str_Block))
	return {s = bytes, n = u32(n), kind = .String, held = true}, bytes, .Ok
}

// A copy of `s` the run owns.
@(require_results)
text_value :: proc(h: ^Heap, s: string) -> (res: Value, status: Status) {
	v, p, st := make_text(h, len(s))
	if st != .Ok {
		return NULL, st
	}
	runtime.mem_copy_non_overlapping(p, raw_data(s), len(s))
	return v, .Ok
}

// `a` followed by `b`, both strings.
@(require_results)
text_concat :: proc(h: ^Heap, a, b: Value) -> (res: Value, status: Status) {
	x, y := text_of(a), text_of(b)
	if len(y) == 0 {
		return retain(a), .Ok
	}
	if len(x) == 0 {
		return retain(b), .Ok
	}
	v, p, s := make_text(h, len(x) + len(y))
	if s != .Ok {
		return NULL, s
	}
	runtime.mem_copy_non_overlapping(p, raw_data(x), len(x))
	runtime.mem_copy_non_overlapping(p[len(x):], raw_data(y), len(y))
	return v, .Ok
}

// Appends the bytes `b` to the string `acc^` owns, in place when it holds its block alone and the block has room,
// growing it by doubling when alone, else into a new string that replaces it.
@(require_results)
text_append :: proc(h: ^Heap, acc: ^Value, b: string) -> Status {
	if len(b) == 0 {
		return .Ok
	}
	v := acc^
	n := int(v.n)
	if v.kind == .String && unique(v) {
		x := (^Str_Block)(block_of(v))
		if n + len(b) <= int(x.cap) {
			runtime.mem_copy_non_overlapping(v.s[n:], raw_data(b), len(b))
			acc.n = u32(n + len(b))
			return .Ok
		}
	}
	a := text_of(v)
	w, p, s := make_text(h, len(a) + len(b), 2 * (len(a) + len(b)) if v.kind == .String && unique(v) else 0)
	if s != .Ok {
		return s
	}
	runtime.mem_copy_non_overlapping(p, raw_data(a), len(a))
	runtime.mem_copy_non_overlapping(p[len(a):], raw_data(b), len(b))
	release(h, v)
	acc^ = w
	return .Ok
}

// The code points of `s`, each maximal ill-formed subsequence counted as one, as U+FFFD reads it.
codepoint_count :: proc "contextless" (s: string) -> int {
	n := 0
	i := 0
	for i < len(s) {
		c := s[i]
		if c < 0x80 {
			i += 1
		} else {
			_, w := utf8.decode_rune_in_string(s[i:])
			i += w
		}
		n += 1
	}
	return n
}

// The byte offset of code point `k` of `s`, `len(s)` past its last, counting as `codepoint_count` does.
codepoint_offset :: proc "contextless" (s: string, k: int) -> int {
	i := 0
	for _ in 0 ..< k {
		if i >= len(s) {
			return len(s)
		}
		if s[i] < 0x80 {
			i += 1
		} else {
			_, w := utf8.decode_rune_in_string(s[i:])
			i += w
		}
	}
	return i
}

// The code points of `s`, ill-formed bytes read as U+FFFD, as an array of integers.
@(require_results)
explode :: proc(h: ^Heap, s: string) -> (res: Value, status: Status) {
	a := make_array(h, codepoint_count(s)) or_return
	for r in s {
		append_owned(h, &a, int_value(i64(r))) or_return
	}
	return a, .Ok
}

// The UTF-8 string of code points `cps`, each an integer in range that is no surrogate, which `bad` names otherwise.
@(require_results)
implode :: proc(h: ^Heap, cps: []i64) -> (v: Value, bad: int, s: Status) {
	n := 0
	for c, i in cps {
		if c < 0 || c > 0x10FFFF || c >= 0xD800 && c < 0xE000 {
			return NULL, i, .Ok
		}
		n += utf8.rune_size(rune(c))
	}
	p: [^]u8
	v, p, s = make_text(h, n)
	if s != .Ok {
		return
	}
	at := 0
	for c in cps {
		bytes, w := utf8.encode_rune(rune(c))
		copy(p[at:at + w], bytes[:w])
		at += w
	}
	return v, -1, .Ok
}

// Whether every byte of `s` is below 0x80.
is_ascii :: proc "contextless" (s: string) -> bool {
	for c in transmute([]u8)s {
		if c >= 0x80 {
			return false
		}
	}
	return true
}

// `s` with ASCII letters made lower case, or upper with `upper`, other bytes as they are.
@(require_results)
ascii_case :: proc(h: ^Heap, v: Value, upper: bool) -> (res: Value, status: Status) {
	s := text_of(v)
	changes := false
	for c in transmute([]u8)s {
		if upper && c - 'a' < 26 || !upper && c - 'A' < 26 {
			changes = true
			break
		}
	}
	if !changes {
		return retain(v), .Ok
	}
	w, p, st := make_text(h, len(s))
	if st != .Ok {
		return NULL, st
	}
	for c, i in transmute([]u8)s {
		p[i] = c ~ 0x20 if upper && c - 'a' < 26 || !upper && c - 'A' < 26 else c
	}
	return w, .Ok
}

// The part of string `v` from code point `from` to before `to`, both clamped to it.
@(require_results)
text_slice :: proc(h: ^Heap, v: Value, from, to: int) -> (res: Value, status: Status) {
	s := text_of(v)
	if to <= from {
		return text_borrowed(""), .Ok
	}
	lo := codepoint_offset(s, from)
	hi := lo + codepoint_offset(s[lo:], to - from)
	if lo == 0 && hi == len(s) {
		return retain(v), .Ok
	}
	return text_value(h, s[lo:hi])
}

// `s` repeated `n` times, `n` at least 1.
@(require_results)
text_repeat :: proc(h: ^Heap, v: Value, n: int) -> (res: Value, status: Status) {
	s := text_of(v)
	if n == 1 {
		return retain(v), .Ok
	}
	total := len(s) * n
	if n != 0 && total / n != len(s) || u64(total) > u64(max(u32)) {
		return NULL, fail(h, .Range, .Repeat, v)
	}
	w, p, st := make_text(h, total)
	if st != .Ok {
		return NULL, st
	}
	for i in 0 ..< n {
		runtime.mem_copy_non_overlapping(p[i * len(s):], raw_data(s), len(s))
	}
	return w, .Ok
}

// The byte offsets where `sep`, not empty, starts in `s`, overlapping ones included.
text_find_all :: proc(s, sep: string, into: ^[dynamic]int) -> runtime.Allocator_Error {
	if len(sep) == 0 || len(sep) > len(s) {
		return nil
	}
	for i := 0; i + len(sep) <= len(s); i += 1 {
		if s[i] == sep[0] && s[i:i + len(sep)] == sep {
			append(into, i) or_return
		}
	}
	return nil
}

// The parts of string `v` between the occurrences of `sep`, as an array of strings, an empty `sep` splitting it into
// its code points. An empty `v` has no part.
@(require_results)
text_split :: proc(h: ^Heap, v: Value, sep: string) -> (res: Value, status: Status) {
	s := text_of(v)
	a := make_array(h, 0) or_return
	if len(s) == 0 {
		return a, .Ok
	}
	if len(sep) == 0 {
		for i := 0; i < len(s); {
			w := 1
			if s[i] >= 0x80 {
				_, w = utf8.decode_rune_in_string(s[i:])
			}
			part := text_value(h, s[i:i + w]) or_return
			append_owned(h, &a, part) or_return
			i += w
		}
		return a, .Ok
	}
	at := 0
	for i := 0; i + len(sep) <= len(s); {
		if s[i:i + len(sep)] == sep {
			part := text_value(h, s[at:i]) or_return
			append_owned(h, &a, part) or_return
			i += len(sep)
			at = i
		} else {
			i += 1
		}
	}
	part := text_value(h, s[at:]) or_return
	append_owned(h, &a, part) or_return
	return a, .Ok
}

// Whether code point `r` is white space by Unicode's White_Space property.
is_space :: proc "contextless" (r: rune) -> bool {
	switch r {
	case 0x09 ..= 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
		return true
	}
	return false
}

// String `v` without white space at its start (`left`) and its end (`right`).
@(require_results)
text_trim :: proc(h: ^Heap, v: Value, left, right: bool) -> (res: Value, status: Status) {
	s := text_of(v)
	lo, hi := 0, len(s)
	if left {
		for lo < hi {
			r, w := utf8.decode_rune_in_string(s[lo:])
			if !is_space(r) {
				break
			}
			lo += w
		}
	}
	if right {
		for hi > lo {
			r, w := utf8.decode_last_rune_in_string(s[lo:hi])
			if !is_space(r) {
				break
			}
			hi -= w
		}
	}
	if lo == 0 && hi == len(s) {
		return retain(v), .Ok
	}
	return text_value(h, s[lo:hi])
}

// A hash of the bytes of `s`, FNV-1a widened by a final mix.
hash_text :: proc "contextless" (s: string) -> u64 {
	x := u64(0xCBF29CE484222325)
	for c in transmute([]u8)s {
		x = (x ~ u64(c)) * 0x100000001B3
	}
	return mix64(x)
}
