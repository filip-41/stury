package jq

// jq's regular expressions (`test`, `match`, `capture`, `scan`, `split/2`, `sub`, `gsub`) on cmd/stury/regex,
// which matches as Oniguruma does under jq's options. Offsets and lengths count characters as jq 1.8.2
// counts them, which a global search makes odd: after an empty match it goes on one byte later, which may
// be inside a character.

import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../regex"

Regex :: struct {
	re:     regex.Regex,
	global: bool,
}

// A match's bounds: the whole match's at 0 and 1, then two per group, -1 for a group that did not take part.
Match :: []int

compile_regex :: proc(ip: ^Interp, pattern: string, flags: Value) -> (r: Regex, sig: Signal) {
	opts: regex.Flags
	longest, not_empty := false, false
	if kind(flags) != .Null {
		f, ok := string_of(flags)
		if !ok {
			return r, fail(ip, "%s (%s) is not a string", type_name(flags), brief(flags))
		}
		for c in f {
			switch c {
			case 'g':
				r.global = true
			case 'i':
				opts.fold = true
			case 'x':
				opts.extend = true
			case 'n':
				not_empty = true
			case 'm', 'p':
				opts.dotall = true
			case 'l':
				longest = true
			case 's':
			case:
				return r, fail(ip, "%s is not a valid modifier string", f)
			}
		}
	}
	err: string
	if r.re, err = cached_compile(pattern, opts); err != "" {
		return r, fail(ip, "Regex failure: %s", err)
	}
	r.re.longest, r.re.not_empty = longest, not_empty
	return r, .Go
}

// The regexes the thread compiled, kept for later calls since a filter compiles its patterns for every input. An
// entry is never replaced, so a regex stays whole while a caller reads it. Past the cap, and for long patterns, a
// regex is compiled for its call alone.
@(private = "file")
CACHED_REGEXES :: 64
@(private = "file")
CACHED_PATTERN_BYTES :: 1024

@(private = "file")
Cached_Regex :: struct {
	pattern: string,
	opts:    regex.Flags,
	re:      regex.Regex,
}

@(private = "file", thread_local)
regex_cache: struct {
	arena:   virtual.Arena,
	ready:   bool,
	entries: [dynamic]Cached_Regex,
}

@(private = "file")
cached_compile :: proc(pattern: string, opts: regex.Flags) -> (regex.Regex, string) {
	c := &regex_cache
	for &e in c.entries {
		if e.pattern == pattern && e.opts == opts {
			return e.re, ""
		}
	}
	if len(c.entries) >= CACHED_REGEXES || len(pattern) > CACHED_PATTERN_BYTES {
		return regex.compile(pattern, opts)
	}
	if !c.ready {
		if virtual.arena_init_growing(&c.arena) != nil {
			return regex.compile(pattern, opts)
		}
		c.ready = true
	}
	caller := context.allocator
	context.allocator = virtual.arena_allocator(&c.arena)
	// A pattern that does not compile leaves nothing in the arena. Its message is the caller's.
	mark := virtual.arena_temp_begin(&c.arena)
	re, err := regex.compile(pattern, opts)
	if err != "" {
		err = strings.clone(err, caller)
		virtual.arena_temp_end(mark)
		return {}, err
	}
	virtual.arena_temp_ignore(mark)
	append(&c.entries, Cached_Regex{strings.clone(pattern), opts, re})
	return re, ""
}

// Every match of `r` in `s`, or the first when `r` is not global.
matches :: proc(ip: ^Interp, r: ^Regex, s: string) -> (out: []Match, sig: Signal) {
	width := 2 * len(r.re.names)
	buf: [16]int
	found := buf[:width] if width <= len(buf) else make(Match, width, context.temp_allocator)
	bounds: [dynamic]int
	for at := 0; at <= len(s); {
		ok, err := regex.search(&r.re, s, at, found)
		if err != "" {
			delete(bounds)
			return nil, fail(ip, "Regex failure: %s", err)
		}
		if !ok {
			break
		}
		if !r.global {
			out = make([]Match, 1)
			out[0] = slice.clone(found)
			return out, .Go
		}
		append(&bounds, ..found)
		at = found[1] if found[1] > found[0] else found[1] + 1
	}
	if len(bounds) == 0 {
		return nil, .Go
	}
	out = make([]Match, len(bounds) / width)
	for &m, i in out {
		m = bounds[i * width:][:width]
	}
	return out, .Go
}

// A walk along a string a character at a time, as jq walks it to turn bytes into character indices and back. It moves
// from where it was last asked, so a string's matches in order cost one walk.
Char_Walk :: struct {
	pos, n: int, // n characters start before byte pos
}

// The characters that start before byte `pos`.
@(private = "file")
chars_before :: proc(w: ^Char_Walk, s: string, pos: int) -> int {
	for i in pos ..< w.pos {
		w.n -= int(s[i] & 0xC0 != 0x80)
	}
	for i in w.pos ..< pos {
		w.n += int(s[i] & 0xC0 != 0x80)
	}
	w.pos = pos
	return w.n
}

// The byte where character `idx` starts, or the end.
@(private = "file")
char_start :: proc(w: ^Char_Walk, s: string, idx: int) -> int {
	for w.pos > 0 && w.n > idx {
		w.pos -= 1
		w.n -= int(s[w.pos] & 0xC0 != 0x80)
	}
	for w.pos < len(s) && (w.n < idx || s[w.pos] & 0xC0 == 0x80) {
		w.n += int(s[w.pos] & 0xC0 != 0x80)
		w.pos += 1
	}
	return w.pos
}

// jq's `$s[from:to]` on character indices.
char_slice :: proc(w: ^Char_Walk, s: string, from, to: int) -> string {
	lo := char_start(w, s, max(from, 0))
	return s[lo:char_start(w, s, max(from, to, 0))]
}

// The text between matches as split and sub cut it: jq's `$s[prev:offset]` on character indices, where
// prev is the last match's offset plus its length. When every match starts and ends between characters
// (only the one-byte advance past an empty match lands inside one), that is the text between them.
Cuts :: struct {
	bytes:        bool,
	prev:         int, // the last match's end, or with bytes false its offset plus length
	spans, cuts:  Char_Walk,
}

on_boundaries :: proc(s: string, ms: []Match) -> bool {
	for m in ms {
		for b in m[:2] {
			if b < len(s) && s[b] & 0xC0 == 0x80 {
				return false
			}
		}
	}
	return true
}

// The text before match `m`, after the one before it.
cut_before :: proc(c: ^Cuts, s: string, m: Match) -> string {
	if c.bytes {
		gap := s[c.prev:m[0]]
		c.prev = m[1]
		return gap
	}
	off, length := span(&c.spans, s, m[0], m[1])
	gap := char_slice(&c.cuts, s, c.prev, off)
	c.prev = off + length
	return gap
}

// The text after the last match.
cut_rest :: proc(c: ^Cuts, s: string) -> string {
	return s[c.prev:] if c.bytes else char_slice(&c.cuts, s, c.prev, len(s))
}

// The `offset` and `length` jq gives the bytes lo..hi of a match or group. jq walks the string a character at a time
// from its start and counts. A bound inside a character is never met, so such a span has offset 0 and counts its
// length from the start.
span :: proc(w: ^Char_Walk, s: string, lo, hi: int) -> (offset, length: int) {
	if lo < len(s) && lo < hi && s[lo] & 0xC0 == 0x80 {
		return 0, chars_before(w, s, hi)
	}
	offset = chars_before(w, s, lo)
	return offset, chars_before(w, s, hi) - offset
}

// The bytes lo..hi as jq makes a string of them: a bound inside a character leaves bytes no UTF-8 holds
// alone, each run of which is one U+FFFD.
span_text :: proc(s: string, lo, hi: int) -> string {
	inside :: #force_inline proc(s: string, at: int) -> bool {
		return at < len(s) && s[at] & 0xC0 == 0x80
	}
	text := s[lo:hi]
	return valid_utf8(text) if inside(s, lo) || inside(s, hi) else text
}

// A match as jq's object: `offset`, `length`, `string`, `captures`. In an empty match, jq gives every group
// that took part the match's offset and no text.
match_object :: proc(r: ^Regex, s: string, m: Match, w: ^Char_Walk) -> Value {
	o := new_object()
	off, length := span(w, s, m[0], m[1])
	object_put(o, "offset", num(f64(off)))
	object_put(o, "length", num(f64(length)))
	object_put(o, "string", span_text(s, m[0], m[1]))
	caps := new_array()
	for g in 1 ..< len(r.re.names) {
		c := new_object()
		lo, hi := m[2 * g], m[2 * g + 1]
		switch {
		case lo < 0:
			object_put(c, "offset", num(-1))
			object_put(c, "string", nil)
			object_put(c, "length", num(0))
		case lo == hi || m[0] == m[1]: // jq's own key order for an empty capture
			object_put(c, "offset", num(f64(off if m[0] == m[1] else chars_before(w, s, lo))))
			object_put(c, "string", "")
			object_put(c, "length", num(0))
		case:
			at, n := span(w, s, lo, hi)
			object_put(c, "offset", num(f64(at)))
			object_put(c, "length", num(f64(n)))
			object_put(c, "string", span_text(s, lo, hi))
		}
		name := r.re.names[g]
		object_put(c, "name", name if name != "" else nil)
		append(&caps.items, c)
	}
	object_put(o, "captures", caps)
	return o
}

// A match's named groups as `capture` gives them, `{name: string}`, a later group of a name winning.
capture_object :: proc(r: ^Regex, s: string, m: Match) -> ^Object {
	o := new_object()
	for name, g in r.re.names {
		if g == 0 || name == "" {
			continue
		}
		lo, hi := m[2 * g], m[2 * g + 1]
		text: Value = nil
		if lo >= 0 {
			text = span_text(s, lo, hi) if m[0] < m[1] else ""
		}
		object_put(o, name, text)
	}
	return o
}
