package regex

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// The most bytes a sampled text may grow to.
@(private = "file")
SAMPLE_MAX :: 1 << 12

// The most characters `class_rune` collects from one class to choose among.
@(private = "file")
CHOICES :: 128

// A number of the splitmix64 generator below `n` (above 0), advancing `state`.
@(private = "file")
random_below :: proc(state: ^u64, n: int) -> int {
	state^ += 0x9e3779b97f4a7c15
	z := state^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return int((z ~ (z >> 31)) % u64(max(n, 1)))
}

@(private = "file")
Sampler :: struct {
	out:   strings.Builder,
	state: ^u64,
	extra: int,
}

// A text that the ECMA pattern `pattern` may match, drawn by the splitmix64 generator that `state` holds, which each
// draw advances. A repeat with no upper bound takes up to `extra` more than its lower. An assertion and a look-ahead
// are passed over, so the text is a candidate whose match the caller checks, and a pattern with a back reference, a
// call or a condition gives no text, an error of kind `.Syntax`. A pattern is a search, so a text of fewer than `least`
// characters grows by letters after the match, or before it where the pattern ends with an assertion and starts with
// none. The text comes from `allocator`, and the parse tree from `scratch`, which it is freed to.
sample :: proc(
	pattern: string,
	state: ^u64,
	extra,
	least: int,
	allocator,
	scratch: mem.Allocator,
) -> (text: string, err: Error) {
	spare: [SPARE_BYTES]byte = ---
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, scratch, scratch, block_size = 4096, out_band_size = 1024)
	defer mem.dynamic_arena_destroy(&arena)
	tmp := Gate{inner = mem.dynamic_arena_allocator(&arena), spare = spare[:]}
	text, err = sample_in(pattern, state, extra, least, allocator, gate_allocator(&tmp))
	if tmp.failed {
		return "", MEMORY_OUT
	}
	return
}

@(private = "file")
sample_in :: proc(
	pattern: string,
	state: ^u64,
	extra,
	least: int,
	allocator,
	tree: mem.Allocator,
) -> (text: string, err: Error) {
	context.allocator = tree
	pat, message := parse(pattern, Options{ecma = true})
	if message != "" {
		return "", {.Syntax, message}
	}
	s := Sampler{out = strings.builder_make(tree), state = state, extra = extra}
	if !walk(&s, pat.root) {
		return "", {.Syntax, "pattern cannot be sampled"}
	}
	if gate_failed(tree) {
		return "", MEMORY_OUT
	}
	raw := strings.to_string(s.out)
	pad_len := max(least - utf8.rune_count_in_string(raw), 0)
	off := 0
	if pad_len > 0 && anchors(pat.root, last = true) {
		off = 0 if anchors(pat.root, last = false) else pad_len
		pad_len = off
	}
	if pad_len > max(int) - len(raw) {
		return "", MEMORY_OUT
	}
	buf, aerr := make([]u8, len(raw) + pad_len, allocator)
	if aerr != nil || len(raw) + pad_len > 0 && buf == nil {
		return "", MEMORY_OUT
	}
	copy(buf[off:], raw)
	for &c in (buf[:off] if off > 0 else buf[len(raw):]) {
		c = u8('a' + random_below(state, 26))
	}
	return string(buf), {}
}

// Whether the first (or `last`) thing the pattern `n` matches is a start (or end) of the text.
@(private = "file")
anchors :: proc(root: ^Node, last: bool) -> bool {
	n := root
	for n != nil {
		switch n.kind {
		case .Cat:
			if len(n.kids) == 0 {
				return false
			}
			n = n.kids[len(n.kids) - 1 if last else 0]
		case .Group:
			n = n.kids[0]
		case .Assert:
			if last {
				return n.assert == .End_Buf || n.assert == .Semi_End_Buf || n.assert == .End_Line
			}
			return n.assert == .Begin_Buf || n.assert == .Begin_Line
		case .Empty, .Char, .Str, .Any, .Class, .Alt, .Repeat, .Look, .Backref, .Keep, .Cond, .Linebreak, .Grapheme,
		     .Call, .Absent:
			return false
		}
	}
	return false
}

@(private = "file")
walk :: proc(s: ^Sampler, n: ^Node) -> bool {
	if n == nil || strings.builder_len(s.out) > SAMPLE_MAX {
		return n == nil
	}
	switch n.kind {
	case .Empty, .Assert, .Look, .Keep:
	case .Char:
		strings.write_rune(&s.out, n.r)
	case .Str:
		strings.write_string(&s.out, n.text)
	case .Any:
		strings.write_byte(&s.out, u8('a' + random_below(s.state, 26)))
	case .Class:
		r, ok := class_rune(s, n.class)
		strings.write_rune(&s.out, r)
		return ok
	case .Cat:
		for k in n.kids {
			if !walk(s, k) {
				return false
			}
		}
	case .Alt:
		return len(n.kids) > 0 && walk(s, n.kids[random_below(s.state, len(n.kids))])
	case .Group:
		return walk(s, n.kids[0])
	case .Repeat:
		lo := min(n.min, SAMPLE_MAX)
		span := s.extra if n.max < 0 else min(n.max - n.min, s.extra)
		// An iteration that wrote nothing can be taken for each one left, so a repeat of an empty body ends at once.
		for _ in 0 ..< lo + random_below(s.state, min(max(span, 0), SAMPLE_MAX - lo) + 1) {
			at := strings.builder_len(s.out)
			if !walk(s, n.kids[0]) {
				return false
			}
			if strings.builder_len(s.out) == at {
				break
			}
		}
	case .Backref, .Cond, .Linebreak, .Grapheme, .Call, .Absent:
		return false
	}
	return true
}

// A character of `cls`: one of the printable ASCII it holds, then the ends of its ranges, and failing both the first
// characters of the planes below U+3000.
@(private = "file")
class_rune :: #force_no_inline proc(s: ^Sampler, cls: ^Class) -> (rune, bool) {
	choices: [CHOICES]rune
	n := 0
	for r in rune(0x20) ..= rune(0x7e) {
		if class_match_slow(cls, r) {
			choices[n] = r
			n += 1
		}
	}
	for g in cls.ranges {
		for r in ([2]rune{g[0], g[1]}) {
			if r > 0x7e && n < CHOICES && utf8.valid_rune(r) && class_match_slow(cls, r) {
				choices[n] = r
				n += 1
			}
		}
	}
	for r := rune(0); n == 0 && r < 0x3000; r += 1 {
		if utf8.valid_rune(r) && class_match_slow(cls, r) {
			choices[n] = r
			n += 1
		}
	}
	if n == 0 {
		return 0, false
	}
	return choices[random_below(s.state, n)], true
}
