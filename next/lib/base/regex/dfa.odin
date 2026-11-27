#+private
package regex

// A deterministic automaton that answers whether a program matches anywhere in a text. It is built at compile time
// from a program that reads one character at a time and asserts only the classes of the characters on either side of
// a place (`^`, `$`, `\A`, `\z`, `\Z`, `\b`, `\B`), and from an ECMA program that begins with look-aheads after `^`.
// The automaton of the latter is the product of the program's own and one for each look-ahead's body. A search that
// reads no bounds needs only this answer. Each step reads one character and indexes one table row, so the search is
// one pass over the text whatever the pattern. The automaton is read only, so threads share it.
//
// The automaton decides the program's language and not its order of alternatives. A match exists exactly when some
// path through the program reaches Match, and the rule that an iteration may not match empty removes only paths that
// a path without that iteration reproduces at the same position.

import "base:intrinsics"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/spell"

// Rows of the state with no match left and of the state with a match found. A search stops at either.
DEAD :: 0
MATCHED :: 1

// The classes of the character on either side of a place, as the assertions read it. EDGE is no character, at the
// text's start or end. NEWLINE is a newline read by a line anchor, WORD a word character read by `\b`, OTHER any other
// character. FINAL is a newline that ends the text, read by `\Z` or a line anchor.
EDGE :: 0
NEWLINE :: 1
WORD :: 2
OTHER :: 3
FINAL :: 4
CLASSES :: 5

Dfa :: struct {
	// Each state's row has `stride` entries: the start of the next state's row for each symbol, then for a newline
	// that ends the text, then for the text's end, where a state that matches there goes to the matched row.
	table:   []u32,
	stride:  u32,
	// The rows before `start_end` are the start rows, those of the thread at the program's start alone. There a search
	// may skip to the next place a match can start, the next first byte of `head`. 0 when `head` is not known.
	start_end: u32,
	starts:    [CLASSES]u32, // the row a search starts in, by the class of the character before its start
	final:     u8, // the class of a newline that ends the text
	anchored:  bool, // a start row is read only where a search starts, so a skip tests that byte and does not scan on
	head:      ^Search_Opt,
	ascii:     [128]u8, // each ASCII character's symbol
	bounds:    []rune, // the first of each run of non-ASCII characters that share a symbol, from 0x80
	symbols:   []u8, // the symbol of each run
	classes:   []u8, // each symbol's class
	// The automaton that finds where the first match in the backtracker's order ends. Its rows have the same stride,
	// and an entry has FIRST_ENDS set when a match ends before the character it reads. Nil when it is not built.
	first:        []u32,
	first_starts: [CLASSES]u32,
	first_end:    u32, // the start rows of `first` are the rows before this offset
	// The automaton read backwards from a match's end that finds where the match starts. Its rows have the same
	// stride and their last column is the text's start. An entry has FIRST_ENDS set when a match starts after the
	// character it reads. `last_starts` is indexed by the class of the character after the end. Nil when `first` is.
	last:        []u32,
	last_starts: [CLASSES]u32,
	// For a program with no loop except Reps: its `splits` two-way choices and its Reps' counts bound a backtracker's
	// retries at one start by the text left. -1 for a program with a loop.
	splits: i32,
	reps:   []i32, // each Rep's maximum count, -1 for unbounded
}

#assert(size_of(int) != 8 || size_of(Dfa) == 328)

// Set on an entry of `Dfa.first` when a match ends where the character the entry reads begins. `Dfa.last` sets it when
// a match starts after the character.
FIRST_ENDS :: u32(1) << 31

// Whether `d`'s program matches in `s` at or after byte `start`. `judged` is false when the text holds a byte that does
// not begin a valid UTF-8 character there, or `start` is inside a character. The backtracker's steps decide then.
dfa_search :: #force_no_inline proc(d: ^Dfa, s: string, start: int) -> (found: bool, judged: bool) {
	if start > len(s) {
		return false, true
	}
	before, ok := start_class(d, s, start)
	if !ok {
		return false, false
	}
	end := len(s) - 1 if len(s) > start && s[len(s) - 1] == '\n' else len(s)
	st: u32
	read: bool
	if d.start_end > 0 {
		st, read = scan_whether(d, s, d.starts[before], start, end, true)
	} else {
		st, read = scan_whether(d, s, d.starts[before], start, end, false)
	}
	if !read {
		return false, false
	}
	matched := MATCHED * d.stride
	if st > matched && end < len(s) {
		st = d.table[st + d.stride - 2]
	}
	return st == matched || st > matched && d.table[st + d.stride - 1] == matched, true
}

// Returns the row a whether search reaches from row `st` at byte `i` of `s` up to byte `end`. It stops early when no
// match is left or a match is found. With `$SKIP` it jumps from a start row to the next place a match can start.
// `judged` is false as in `dfa_search`.
@(private = "file")
scan_whether :: #force_inline proc(d: ^Dfa, s: string, st: u32, i, end: int, $SKIP: bool) -> (row: u32, judged: bool) {
	st, i := st, i
	table, matched := d.table, MATCHED * d.stride
	for st > matched && i < end {
		when SKIP {
			if st < d.start_end {
				if i = skip_to_lead(d, s, i); i < 0 {
					return DEAD, true
				}
				before, valid := class_before(d, s, i)
				if !valid {
					return st, false
				}
				if st = d.starts[before]; i >= end {
					break
				}
			}
		}
		b := s[i]
		sym: u8
		if b < 0x80 {
			sym = d.ascii[b]
			i += 1
		} else {
			r, w := utf8.decode_rune_in_string(s[i:])
			if w == 1 {
				return st, false
			}
			sym = rune_symbol(d, r)
			i += w
		}
		st = table[st + u32(sym)]
	}
	return st, true
}

// Returns where the first match in the backtracker's order of `d`'s program at or after byte `start` in `s` ends, -1
// for none. `reach` is the byte past the last character a thread read, which bounds every place the backtracker's
// search visits. `first` is the earliest place the match that ends at `end` can start: the place a skip last landed on
// before that end, since the starts before it were skipped over and over invalid UTF-8 may lie inside a character.
// `judged` is false as in `dfa_search`.
dfa_first :: proc(d: ^Dfa, s: string, start: int) -> (end, reach, first: int, judged: bool) {
	end, first = -1, start
	landing := start
	if start > len(s) {
		return -1, start, start, true
	}
	before, ok := start_class(d, s, start)
	if !ok {
		return -1, start, start, false
	}
	st := d.first_starts[before]
	table := d.first
	last := len(s) - 1 if len(s) > start && s[len(s) - 1] == '\n' else len(s)
	i := start
	for st != DEAD && i < last {
		if st < d.first_end {
			if i = skip_to_lead(d, s, i); i < 0 {
				return -1, start, start, true
			}
			here, valid := class_before(d, s, i)
			if !valid {
				return -1, start, start, false
			}
			landing = i
			if st = d.first_starts[here]; i >= last {
				break
			}
		}
		b := s[i]
		sym: u8
		w := 1
		if b < 0x80 {
			sym = d.ascii[b]
		} else {
			r: rune
			if r, w = utf8.decode_rune_in_string(s[i:]); w == 1 {
				return -1, start, start, false
			}
			sym = rune_symbol(d, r)
		}
		t := table[st + u32(sym)]
		if t & FIRST_ENDS != 0 {
			end, first = i, landing
		}
		st = t &~ FIRST_ENDS
		i += w
	}
	if st != DEAD && last < len(s) {
		t := table[st + d.stride - 2]
		if t & FIRST_ENDS != 0 {
			end, first = last, landing
		}
		st = t &~ FIRST_ENDS
		i = len(s)
	}
	if st != DEAD && table[st + d.stride - 1] & FIRST_ENDS != 0 {
		end, first = len(s), landing
	}
	return end, i, first, true
}

// Returns where the match of `d`'s program that ends at byte `end` of `s` starts: the earliest such place from byte
// `from` on, -1 for none. `judged` is false as in `dfa_search`.
dfa_start :: proc(d: ^Dfa, s: string, from, end: int) -> (start: int, judged: bool) {
	after := EDGE
	if end < len(s) {
		r, w := utf8.decode_rune_in_string(s[end:])
		if w == 1 && s[end] >= 0x80 {
			return -1, false
		}
		after = int(d.classes[d.ascii[r] if r < 0x80 else rune_symbol(d, r)])
		if end == len(s) - 1 && r == '\n' {
			after = int(d.final)
		}
	}
	st := d.last_starts[after]
	table := d.last
	start = -1
	for p := end; st != DEAD; {
		if p == 0 {
			if table[st + d.stride - 1] & FIRST_ENDS != 0 {
				start = 0
			}
			break
		}
		r, w := utf8.decode_last_rune_in_string(s[:p])
		if w == 1 && s[p - 1] >= 0x80 {
			return -1, false
		}
		col := u32(d.ascii[r] if r < 0x80 else rune_symbol(d, r))
		if p == len(s) && r == '\n' {
			col = d.stride - 2
		}
		t := table[st + col]
		if t & FIRST_ENDS != 0 {
			start = p
		}
		if p <= from {
			break
		}
		st = t &~ FIRST_ENDS
		p -= w
	}
	return start, start >= 0
}

// Returns the next place from `i` where a match can start, or -1 for none. Only a program with a known head enters a
// start row (`start_end` / `first_end` is 0 otherwise).
@(private = "file")
skip_to_lead :: #force_inline proc(d: ^Dfa, s: string, i: int) -> int {
	h := d.head
	if d.anchored {
		lead := h.exact[0] == s[i] if h.kind == .Exact else has_bit(h.set[:], int(s[i]))
		return i if lead else -1
	}
	if h.kind == .Exact {
		k := strings.index_byte(s[i:], h.exact[0])
		return i + k if k >= 0 else -1
	}
	return next_head_byte(h, s, i)
}

// Returns the class of the character before byte `i` of `s`, EDGE at 0. `valid` is false when the bytes before `i` do
// not end a valid character, which the backtracker reads by other rules.
@(private = "file")
class_before :: #force_inline proc(d: ^Dfa, s: string, i: int) -> (class: int, valid: bool) {
	if i == 0 {
		return EDGE, true
	}
	if s[i - 1] < 0x80 {
		return int(d.classes[d.ascii[s[i - 1]]]), true
	}
	r, w := utf8.decode_last_rune_in_string(s[:i])
	return int(d.classes[rune_symbol(d, r)]), w > 1
}

// Returns the class of the character before byte `start` of `s`, EDGE at 0, and the final class for a newline that ends
// `s`. `ok` is false when `start` is inside a character or the text before it is not valid UTF-8.
@(private = "file")
start_class :: proc(d: ^Dfa, s: string, start: int) -> (before: int, ok: bool) {
	if start == 0 {
		return EDGE, true
	}
	if start < len(s) && spell.is_continuation(s[start]) {
		return 0, false
	}
	if start == len(s) && s[start - 1] == '\n' {
		return int(d.final), true
	}
	return class_before(d, s, start)
}

@(private = "file")
rune_symbol :: #force_inline proc(d: ^Dfa, r: rune) -> u8 {
	lo, n := 0, len(d.bounds)
	for n > 1 {
		half := n >> 1
		lo = lo + half if d.bounds[lo + half] <= r else lo
		n -= half
	}
	return d.symbols[lo]
}

// Whether a backtracker's search of `d`'s program over `left` bytes stays within `limit` retries at each start.
retries_bounded :: proc(d: ^Dfa, left, limit: int) -> bool {
	if d.splits < 0 || limit < 0 {
		return false
	}
	most, bound := uint(limit), uint(max(int(d.splits) + len(d.reps), 1))
	if bound > most {
		return false
	}
	for _ in 0 ..< d.splits {
		if bound > most >> 1 {
			return false
		}
		bound *= 2
	}
	span := uint(left) + 1
	for r in d.reps {
		next, overflow := intrinsics.overflow_mul(bound, span if r < 0 else min(uint(r), span))
		if overflow || next > most {
			return false
		}
		bound = next
	}
	return true
}
