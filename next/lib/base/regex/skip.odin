#+private
package regex

// Runtime search-start prefiltering, Oniguruma's forward_search and anchor start bounds (regexec.c), and compile-time
// head extraction (`first_bytes`, `literal_prefix`). The search tries only the starts these leave, so a hopeless search
// fails at once where Oniguruma's does, and a start that Oniguruma tries runs into the retry limit as it does.

import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

INFINITE_LEN :: max(int)

@(private = "file")
Search_Kind :: enum u8 {
	None,
	Exact, // a match holds `exact` at a distance from its start
	Map, // a match holds a byte of `set` at a distance from its start
}

@(private = "file")
End_Anchor :: enum u8 {
	None,
	End_Buf, // every match ends at the text's end
	Semi_End_Buf, // or before a newline that ends the text
}

// The string or byte set the search skips by, and the anchors, as Oniguruma's regex_t keeps them.
Search_Opt :: struct {
	lead:               kernel.Byte_Set, // `set` as the kernel scans for it, filled in for a head that is a set
	set:                [4]u64,
	exact:              string,
	dist_min, dist_max: int, // least and greatest distance from the match start to the string or set, or INFINITE_LEN
	threshold:          int, // the fewest bytes past the search's start a match needs
	anc_min, anc_max:   int, // under `end`, a match's least and most bytes
	kind:               Search_Kind,
	anchored:           bool, // every match starts at \A
	end:                End_Anchor,
}

// The bytes a head scan tests one at a time before it scans with the kernel: a candidate within a few bytes is common
// and the scan's setup costs more than testing them.
@(private = "file")
NEAR :: 8

// A rest of the text shorter than this is walked without the scan, whose setup costs more than it saves.
@(private = "file")
SHORT :: 128

// The first place from `at` whose byte is in the set of the head `h`, or -1. The places are those a walk by character
// reaches, stepping `lead_width` from each byte, as Oniguruma's map search does. Over invalid UTF-8 that steps past
// bytes that a scan for the set would stop at. So the scan stops at a byte of `h.lead`, which holds every byte from
// 0x80 too: the bytes before it are ASCII, which the walk reaches one by one, and where it stops at a byte from 0x80
// the walk takes over. `at` must be a place the walk reaches.
next_head_byte :: #force_inline proc(h: ^Search_Opt, s: string, at: int) -> int {
	from := at
	if len(s) - at >= SHORT {
		near := at + NEAR
		for from < near {
			c := s[from]
			if has_bit(h.set[:], int(c)) {
				return from
			}
			if c >= 0x80 {
				break
			}
			from += 1
		}
		if from == near {
			return scan_to_head_byte(h, s, near)
		}
	}
	return walk_head_byte(h, s, from)
}

@(private = "file")
walk_head_byte :: #force_inline proc(h: ^Search_Opt, s: string, from: int) -> int {
	at := from
	for at < len(s) && !has_bit(h.set[:], int(s[at])) {
		at += spell.lead_width(s[at])
	}
	return at if at < len(s) else -1
}

@(private = "file")
scan_to_head_byte :: #force_no_inline proc(h: ^Search_Opt, s: string, from: int) -> int {
	k := kernel.index_set(transmute([]u8)s[from:], h.lead)
	if k < 0 {
		return -1
	}
	at := from + k
	if s[at] >= 0x80 && !has_bit(h.set[:], int(s[at])) {
		return walk_head_byte(h, s, at)
	}
	return at
}

// Computes the starts onig_search tries from `start`: `first` to `last`. `limit` is how far a string or map that the
// optimizer finds may reach. `high` is the last start of the first window, or -1 when the windows are found one at a
// time with `next_window`. Returns ok false when no start can match. Kept out of line so that the matcher inlined into
// `search` keeps its registers.
search_starts :: #force_no_inline proc(
	o: ^Search_Opt,
	s: string,
	start: int,
) -> (
	first, last, limit, high: int,
	ok: bool,
) {
	first, last, limit, high = start, len(s), len(s), INFINITE_LEN
	if o.anchored {
		if start != 0 {
			return
		}
		last = min(1, len(s))
	} else if o.end != .None && len(s) > 0 {
		if first, last = end_bounds(o, s, start); first > last {
			return
		}
	}
	if len(s) - first < o.threshold {
		return
	}
	if o.kind == .None {
		return first, last, limit, high, true
	}
	if o.dist_max == INFINITE_LEN {
		return first, last, limit, high, next_window(o, s, first, limit, nil) >= 0
	}
	if len(s) - last >= o.dist_max {
		limit = last + o.dist_max
	}
	return first, last, limit, -1, true
}

// Oniguruma's forward_search: returns the next start at or past `at`, in a window of starts from low to high that a
// string or map found at a bounded distance gives, and sets `high^` to that window's last start. Returns -1 when there
// is none.
next_window :: #force_no_inline proc(o: ^Search_Opt, s: string, at, limit: int, high: ^int) -> int {
	p := at
	if o.dist_min != 0 {
		if len(s) - p <= o.dist_min {
			return -1
		}
		for q := p + o.dist_min; p < q; {
			p += spell.lead_width(s[p])
		}
	}
	if p >= limit {
		return -1
	}
	if o.kind == .Exact {
		end := limit + min(len(s) - limit, len(o.exact) - 1)
		k := strings.index(s[p:end], o.exact)
		if k < 0 {
			return -1
		}
		p += k
	} else {
		for p < limit && !has_bit(o.set[:], int(s[p])) {
			p += spell.lead_width(s[p])
		}
	}
	if p >= limit {
		return -1
	}
	if o.dist_max == INFINITE_LEN {
		return at
	}
	high^ = max(p - o.dist_min, 0)
	low := max(p - o.dist_max, 0)
	if low > at {
		low = spell.skip_continuations(s, low)
	}
	return max(at, low)
}

// Returns the first and last start of a match that ends at the text's end, or before a newline that ends it, as
// onig_search's end_buf bounds them. `first` is past `last` when there is none. When the text's final newline is also
// its first byte, or lies before `start`, the starts stay unbounded, as onig_search then skips end_buf.
@(private = "file")
end_bounds :: proc(o: ^Search_Opt, s: string, start: int) -> (first, last: int) {
	first, last = start, len(s)
	min_end, max_end := len(s), len(s)
	if o.end == .Semi_End_Buf && s[len(s) - 1] == '\n' {
		if len(s) == 1 || start > len(s) - 1 {
			return
		}
		min_end = len(s) - 1
	}
	if max_end < o.anc_min {
		return 1, 0
	}
	if o.anc_max != INFINITE_LEN && min_end - first > o.anc_max {
		first = min_end - o.anc_max
		first = spell.skip_continuations(s, first)
	}
	if max_end - (last - 1) < o.anc_min {
		if max_end + 1 < o.anc_min {
			return 1, 0
		}
		last = max_end - o.anc_min + 1
	}
	return
}

// Adds to `set` every byte a match of `n` can start with. `ok` is false when that is not known, and `empty` is true
// when `n` can match without a byte, so what follows it starts the match too.
first_bytes :: proc(n: ^Node, set: ^[4]u64) -> (empty: bool, ok: bool) {
	add_rune :: proc(set: ^[4]u64, r: rune) {
		if !utf8.valid_rune(r) {
			return
		}
		buf, _ := utf8.encode_rune(r)
		add_bit(set[:], int(buf[0]))
		if r >= 0x80 && r < 0xC0 { // a search that starts inside a character reads the byte r itself
			add_bit(set[:], int(r))
		}
	}
	switch n.kind {
	case .Empty, .Assert, .Keep:
		return true, true
	case .Char:
		add_rune(set, n.r)
		if n.fold {
			for x := fold_next(n.r); x != n.r; x = fold_next(x) {
				add_rune(set, x)
			}
		}
		return false, true
	case .Str:
		add_rune(set, n.r)
		return false, true
	case .Any:
		if n.dotall {
			return false, false
		}
		set[0] |= ~u64(1 << '\n')
		set[1], set[2], set[3] = max(u64), max(u64), max(u64)
		return false, true
	case .Class:
		set[0] |= n.class.ascii[0] // filled when the class was emitted
		set[1] |= n.class.ascii[1]
		if !ascii_only(n.class) || folds_out_of_ascii(n.class) {
			set[2], set[3] = max(u64), max(u64)
		}
		return false, true
	case .Linebreak:
		for b in ([]byte{'\n', '\v', '\f', '\r', 0xC2, 0xE2}) {
			add_bit(set[:], int(b))
		}
		return false, true
	case .Cat:
		for k in n.kids {
			empty, ok = first_bytes(k, set)
			if !ok || !empty {
				return
			}
		}
		return true, true
	case .Alt:
		for k in n.kids {
			e, o := first_bytes(k, set)
			if !o {
				return false, false
			}
			empty ||= e
		}
		return empty, true
	case .Group:
		return first_bytes(n.kids[0], set)
	case .Repeat:
		if n.max == 0 {
			return true, true
		}
		empty, ok = first_bytes(n.kids[0], set)
		return empty || n.min == 0, ok
	case .Look:
		if n.look == .Atomic {
			return first_bytes(n.kids[0], set)
		}
		if n.look == .Ahead {
			if e, o := first_bytes(n.kids[0], set); o && !e {
				return false, true // the match starts where the look-ahead's does
			}
		}
		return true, true // consumes no bytes, so what follows starts the match
	case .Backref, .Cond, .Grapheme, .Call, .Absent:
	}
	return false, false
}

// Appends to `out` the literal every match of `n` starts with. Returns whether `n` is wholly that literal.
literal_prefix :: proc(n: ^Node, out: ^[dynamic]byte) -> bool {
	#partial switch n.kind {
	case .Char, .Str:
		if !literal(n) {
			return false
		}
		buf: [4]byte
		append(out, literal_text(n, &buf))
		return true
	case .Cat:
		for k in n.kids {
			if !literal_prefix(k, out) {
				return false
			}
		}
		return true
	case .Group:
		return literal_prefix(n.kids[0], out)
	case .Repeat:
		// A counted literal is searched as the text it spells, so that a long run does not retry at each start.
		one: [dynamic]byte
		defer delete(one)
		if n.min == 0 || !literal_prefix(n.kids[0], &one) || len(one) == 0 || len(one) > PREFIX_MAXLEN / n.min {
			return false
		}
		for _ in 0 ..< n.min {
			append(out, ..one[:])
		}
		return n.max == n.min
	}
	return false
}

// The most bytes of a literal prefix built from a counted repeat.
@(private = "file")
PREFIX_MAXLEN :: 1 << 16
