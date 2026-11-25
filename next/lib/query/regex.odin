package query

import "core:mem"
import "core:strings"
import "stury:lib/base/regex"

// Regular expressions over a value's text, by dialect: a pattern compiled once and kept for the run, its matches as
// byte bounds, and the walk from bytes to code points. The language picks the dialect and the flags and shapes what
// a match reports.

Regex :: regex.Regex
Regex_Dialect :: regex.Syntax
Regex_Flags :: regex.Flags

@(private)
REGEX_CACHED :: 64 // the patterns kept, past which the cache starts over

@(private)
Cached_Regex :: struct {
	pattern: string, // in the cache's arena
	dialect: Regex_Dialect,
	flags:   Regex_Flags,
	re:      ^Regex, // in the cache's arena
}

// The patterns a run compiled and the matcher's working memory, which live until `regex_cache_destroy`. A pattern is
// valid until the next `regex_compile`, which may start the cache over, so a caller compiles and matches within one
// operation. A zero cache is empty.
Regex_Cache :: struct {
	arena:   mem.Dynamic_Arena,
	ready:   bool,
	entries: [dynamic]Cached_Regex,
	scratch: regex.Scratch,
	message: [dynamic]u8, // the last pattern error's text, which an error's `detail` borrows
}

// The compiled `pattern` under `dialect` and `flags`, from the cache or compiled now. A pattern that does not compile
// fails with `.Pattern`, `.Match`, `a` the pattern and `detail` the matcher's message, which lives until the cache's
// next failure.
regex_compile :: proc(h: ^Heap, c: ^Regex_Cache, pattern: Value, dialect: Regex_Dialect, flags: Regex_Flags) -> (re: ^Regex, status: Status) {
	text := text_of(pattern)
	for &e in c.entries {
		if e.pattern == text && e.dialect == dialect && e.flags == flags {
			return e.re, .Ok
		}
	}
	if !c.ready {
		counted := heap_allocator(h)
		mem.dynamic_arena_init(&c.arena, counted, counted, block_size = 16 << 10, out_band_size = 4 << 10)
		c.entries = make([dynamic]Cached_Regex, counted)
		c.ready = true
	} else if len(c.entries) >= REGEX_CACHED {
		clear(&c.entries)
		mem.dynamic_arena_reset(&c.arena)
	}
	arena := mem.dynamic_arena_allocator(&c.arena)
	compiled, err := regex.compile(text, dialect, flags, arena, heap_allocator(h), spans = true)
	if err.kind != .None {
		return nil, regex_failed(h, c, err, pattern)
	}
	re = new_clone(compiled, arena)
	own, _ := strings.clone(text, arena)
	append(&c.entries, Cached_Regex{pattern = own,dialect = dialect, flags = flags, re = re})
	return re, .Ok
}

@(private)
regex_failed :: proc(h: ^Heap, c: ^Regex_Cache, err: regex.Error, pattern := ABSENT) -> Status {
	if err.kind == .Memory {
		return fail_memory(h)
	}
	clear(&c.message)
	c.message.allocator = heap_allocator(h)
	append(&c.message, err.message)
	return fail(h, .Pattern, .Match, pattern, detail = string(c.message[:]))
}

// The groups of `re`, not counting the whole match.
regex_groups :: proc "contextless" (re: ^Regex) -> int {
	return len(regex.group_names(re)) - 1
}

// Group `g`'s name, "" for none. The text lives as long as the pattern.
regex_group_name :: proc "contextless" (re: ^Regex, g: int) -> string {
	return regex.group_names(re)[g]
}

// The first match of `re` in `s` at or after byte `at`, its bounds in `found`: two byte positions per group, the
// whole match first, -1 for a group that took no part. `found` holds two ints for at most each group, or none to ask
// only whether there is a match. A search that gives up fails with `.Pattern` and the matcher's message.
regex_search :: proc(h: ^Heap, c: ^Regex_Cache, re: ^Regex, s: string, at: int, found: []int) -> (hit: bool, status: Status) {
	if c.scratch.held.gate == nil {
		scratch, err := regex.scratch_make(heap_allocator(h))
		if err.kind != .None {
			return false, fail_memory(h)
		}
		c.scratch = scratch
	}
	err: regex.Error
	hit, err = regex.search(re, s, at, found, &c.scratch)
	if err.kind != .None {
		return false, regex_failed(h, c, err)
	}
	return hit, .Ok
}

regex_cache_destroy :: proc(c: ^Regex_Cache) {
	if c.ready {
		delete(c.entries)
		mem.dynamic_arena_destroy(&c.arena)
	}
	delete(c.message)
	regex.scratch_destroy(&c.scratch)
	c^ = {}
}

// A walk along a text a code point at a time that turns byte positions into code point indexes and back. It moves from
// where it was last asked, so positions asked in order cost one walk of the text.
Code_Walk :: struct {
	pos, n: int, // n code points start before byte pos
}

// The code points that start before byte `pos`.
code_points_before :: proc "contextless" (w: ^Code_Walk, s: string, pos: int) -> int {
	for i in pos ..< w.pos {
		w.n -= int(s[i] & 0xC0 != 0x80)
	}
	for i in w.pos ..< pos {
		w.n += int(s[i] & 0xC0 != 0x80)
	}
	w.pos = pos
	return w.n
}

// The byte where code point `idx` starts, or the end of `s`.
code_point_start :: proc "contextless" (w: ^Code_Walk, s: string, idx: int) -> int {
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
