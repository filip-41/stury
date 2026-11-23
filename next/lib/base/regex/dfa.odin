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

import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/kernel"

// Limits on the automaton and its build. A program past any of them gets no automaton and the visited set answers.
DFA_MAX_ITEMS :: 2048
DFA_MAX_STATES :: 1024
DFA_MAX_SYMBOLS :: 255
DFA_MAX_TABLE :: 1 << 18 // entries of the table, its rows times their stride
DFA_MAX_WORK :: 1 << 18 // instructions visited, set entries moved, ranges and cuts swept
DFA_MAX_LOOKS :: 8 // leading look-aheads, each a component of the product's states

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
	starts:  [CLASSES]u32, // the row a search starts in, by the class of the character before its start
	ascii:   [128]u8, // each ASCII character's symbol
	bounds:  []rune, // the first of each run of non-ASCII characters that share a symbol, from 0x80
	symbols: []u8, // the symbol of each run
	classes: []u8, // each symbol's class
	final:   u8, // the class of a newline that ends the text
	// The rows before `start_end` are the start rows, those of the thread at the program's start alone. There a search
	// may skip to the next place a match can start, the next first byte of `head`. 0 when `head` is not known.
	start_end: u32,
	head:      Search_Opt,
	lead:      kernel.Byte_Set, // `head.set` as the kernel scans for it, when `head` is a set
	anchored:  bool, // a start row is read only where a search starts, so a skip tests that byte and does not scan on
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
	// For a program with no loop except Reps: at most `choices` alternatives are tried for each way through its
	// `splits` two-way choices and its Reps' counts, so a backtracker's retries at one start are bounded by the text
	// left. -1 for a program with a loop.
	choices, splits: int,
	reps:            []i32, // each Rep's maximum count, -1 for unbounded
}

// Set on an entry of `Dfa.first` when a match ends where the character the entry reads begins. `Dfa.last` sets it when
// a match starts after the character.
FIRST_ENDS :: u32(1) << 31

// Whether `d`'s program matches in `s` at or after byte `start`. `judged` is false when the text holds a byte that does
// not begin a valid UTF-8 character there, or `start` is inside a character. The backtracker's steps decide then.
dfa_search :: proc(d: ^Dfa, s: string, start: int) -> (found: bool, judged: bool) {
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
				if st = d.starts[class_before(d, s, i)]; i >= end {
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
// search visits. `judged` is false as in `dfa_search`.
dfa_first :: proc(d: ^Dfa, s: string, start: int) -> (end, reach: int, judged: bool) {
	end = -1
	if start > len(s) {
		return -1, start, true
	}
	before, ok := start_class(d, s, start)
	if !ok {
		return -1, start, false
	}
	st := d.first_starts[before]
	table := d.first
	last := len(s) - 1 if len(s) > start && s[len(s) - 1] == '\n' else len(s)
	i := start
	for st != DEAD && i < last {
		if st < d.first_end {
			if i = skip_to_lead(d, s, i); i < 0 {
				return -1, start, true
			}
			if st = d.first_starts[class_before(d, s, i)]; i >= last {
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
				return -1, start, false
			}
			sym = rune_symbol(d, r)
		}
		t := table[st + u32(sym)]
		if t & FIRST_ENDS != 0 {
			end = i
		}
		st = t &~ FIRST_ENDS
		i += w
	}
	if st != DEAD && last < len(s) {
		t := table[st + d.stride - 2]
		if t & FIRST_ENDS != 0 {
			end = last
		}
		st = t &~ FIRST_ENDS
		i = len(s)
	}
	if st != DEAD && table[st + d.stride - 1] & FIRST_ENDS != 0 {
		end = len(s)
	}
	return end, i, true
}

// Returns where the match of `d`'s program that ends at byte `end` of `s` starts: the earliest such place from byte
// `from` on, -1 for none. `judged` is false as in `dfa_search`.
dfa_start :: proc(d: ^Dfa, s: string, from, end: int) -> (start: int, judged: bool) {
	after := EDGE
	if end < len(s) {
		r, w := decode(s, end)
		if w == 1 && s[end] >= 0x80 || s[end] & 0xC0 == 0x80 {
			return -1, false
		}
		after = int(d.classes[symbol_of(d, r)])
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
		col := u32(symbol_of(d, r))
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

// The bytes a skip tests one at a time before it scans with the kernel.
@(private = "file")
NEAR :: 8

// Returns the next place from `i` where a match can start, `i` itself when `head` gives no first byte, or -1 for none.
// Only a program that cannot match empty has a head.
@(private = "file")
skip_to_lead :: #force_inline proc(d: ^Dfa, s: string, i: int) -> int {
	h := &d.head
	if d.anchored {
		lead := h.exact[0] == s[i] if h.kind == .Exact else h.kind == .None || has_bit(h.set[:], int(s[i]))
		return i if lead else -1
	}
	#partial switch h.kind {
	case .Exact:
		k := strings.index_byte(s[i:], h.exact[0])
		return i + k if k >= 0 else -1
	case .Map:
		// A candidate within a few bytes is common, and the kernel's scan costs more than testing them.
		near := min(i + NEAR, len(s))
		for j in i ..< near {
			if has_bit(h.set[:], int(s[j])) {
				return j
			}
		}
		return skip_far(d, s, near)
	}
	return i
}

// The next place from `from` where a match can start, for a head that is a set. It is kept out of line so the scan's
// loops stay out of the automaton's.
@(private = "file")
skip_far :: #force_no_inline proc(d: ^Dfa, s: string, from: int) -> int {
	k := kernel.index_set(transmute([]u8)s[from:], d.lead)
	return from + k if k >= 0 else -1
}

// Returns the class of the character before byte `i` of `s`, EDGE at 0. Above 0, `i` must start a valid character.
@(private = "file")
class_before :: #force_inline proc(d: ^Dfa, s: string, i: int) -> int {
	if i == 0 {
		return EDGE
	}
	if s[i - 1] < 0x80 {
		return int(d.classes[d.ascii[s[i - 1]]])
	}
	r, _ := utf8.decode_last_rune_in_string(s[:i])
	return int(d.classes[rune_symbol(d, r)])
}

// Returns the class of the character before byte `start` of `s`, EDGE at 0, and the final class for a newline that ends
// `s`. `ok` is false when `start` is inside a character or the text before it is not valid UTF-8.
@(private = "file")
start_class :: proc(d: ^Dfa, s: string, start: int) -> (before: int, ok: bool) {
	if start == 0 {
		return EDGE, true
	}
	r, w := utf8.decode_last_rune_in_string(s[:start])
	if w == 1 && s[start - 1] >= 0x80 || start < len(s) && s[start] & 0xC0 == 0x80 {
		return 0, false
	}
	if start == len(s) && r == '\n' {
		return int(d.final), true
	}
	return int(d.classes[symbol_of(d, r)]), true
}

@(private = "file")
symbol_of :: #force_inline proc(d: ^Dfa, r: rune) -> u8 {
	return d.ascii[r] if r < 0x80 else rune_symbol(d, r)
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
	if d.choices < 0 {
		return false
	}
	bound := max(d.choices, 1)
	for _ in 0 ..< d.splits {
		if bound *= 2; bound > limit {
			return false
		}
	}
	for r in d.reps {
		if bound *= left + 1 if r < 0 else min(int(r), left + 1); bound > limit {
			return false
		}
	}
	return true
}
