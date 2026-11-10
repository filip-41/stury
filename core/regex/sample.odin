package regex

import "core:strings"
import "core:unicode/utf8"

// The most bytes a sampled text may grow to.
@(private = "file")
SAMPLE_MAX :: 1 << 12

// The most characters one class is offered as a choice of.
@(private = "file")
CHOICES :: 128

// The generator that sampled texts, and the values a caller draws beside them, come from: a splitmix64 of one seed.
Source :: struct {
	state: u64,
}

// The next number of `s`.
random_next :: proc(s: ^Source) -> u64 {
	s.state += 0x9e3779b97f4a7c15
	z := s.state
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// A number of `s` below `n`, which is above 0.
random_below :: proc(s: ^Source, n: int) -> int {
	return int(random_next(s) % u64(max(n, 1)))
}

@(private = "file")
Sampler :: struct {
	out:   strings.Builder,
	src:   ^Source,
	extra: int,
}

// A text that the ECMA pattern `pattern` may match, drawn from `src`. A repeat with no upper bound takes up to
// `extra` more than its lower. An assertion and a look-ahead are passed over, so the text is a candidate whose match
// the caller checks, and a pattern with a back reference, a call or a condition gives no text. A pattern is a search,
// so a text of fewer than `least` characters grows by letters after the match, or before it where the pattern ends
// with an assertion and starts with none.
sample :: proc(pattern: string, src: ^Source, extra, least: int, allocator := context.allocator) -> (text: string, ok: bool) {
	pat, err := parse(pattern, Flags{ecma = true})
	if err != "" {
		return
	}
	s := Sampler {
		out   = strings.builder_make(allocator),
		src   = src,
		extra = extra,
	}
	if ok = walk(&s, pat.root); !ok {
		strings.builder_destroy(&s.out)
		return
	}
	text = strings.to_string(s.out)
	if missing := least - utf8.rune_count_in_string(text); missing > 0 {
		pad := make([]u8, missing, allocator)
		for &c in pad {
			c = u8('a' + random_below(src, 26))
		}
		switch {
		case !anchors(pat.root, last = true):
			text = strings.concatenate({text, string(pad)}, allocator)
		case !anchors(pat.root, last = false):
			text = strings.concatenate({string(pad), text}, allocator)
		}
	}
	return text, true
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
		case .Empty, .Char, .Str, .Any, .Class, .Alt, .Repeat, .Look, .Backref, .Keep, .Cond, .Linebreak, .Grapheme, .Call, .Absent:
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
		strings.write_byte(&s.out, u8('a' + random_below(s.src, 26)))
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
		return len(n.kids) > 0 && walk(s, n.kids[random_below(s.src, len(n.kids))])
	case .Group:
		return walk(s, n.kids[0])
	case .Repeat:
		span := s.extra if n.max < 0 else min(n.max - n.min, s.extra)
		for _ in 0 ..< n.min + random_below(s.src, max(span, 0) + 1) {
			if !walk(s, n.kids[0]) {
				return false
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
class_rune :: proc(s: ^Sampler, cls: ^Class) -> (rune, bool) {
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
	return choices[random_below(s.src, n)], true
}
