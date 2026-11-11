#+private
package regex

// A deterministic automaton that answers whether a program matches anywhere in a text, built whole at compile time
// from the program when it reads one character at a time and asserts nothing but what the characters on either side
// of a place are (`^`, `$`, `\A`, `\z`, `\Z`, `\b`, `\B`). A search that reads no bounds asks only that question. Each step
// reads one character and takes one row of the table, so the answer costs one pass over the text whatever the
// pattern, and the automaton is read only, so threads share it.
//
// The automaton runs the program's language and not its order of alternatives, which is the same answer: a match
// exists exactly when some path through the program reaches Match, and the rule that an iteration may not match empty
// removes no path that a path without that iteration does not stand in for at the same position.
//
// A state is the program's threads after the characters read so far, with the class of the last of them. A thread is
// a reading item, or an instruction its closure is still to be followed from: an assertion reads the class of the
// character after its place, so the closures are followed as the next symbol is read, whose class the table knows.
//
// Every step of the build is charged to one budget, and the build gives up past it, so its time and its working
// memory are bounded by the budget and the program's length whatever the pattern. The working memory is freed before
// the build returns, and only the automaton is kept.

import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// The caps on the automaton and its build. Past any of them the program has none and the visited set answers instead.
@(private = "file")
DFA_MAX_ITEMS :: 2048
@(private = "file")
DFA_MAX_STATES :: 1024
@(private = "file")
DFA_MAX_SYMBOLS :: 255
@(private = "file")
DFA_MAX_TABLE :: 1 << 18 // entries of the table, its rows times their stride
@(private = "file")
DFA_MAX_WORK :: 1 << 18 // instructions visited, set entries moved, ranges and cuts swept

// The rows of no match left and of a match found, which the search stops at.
@(private = "file")
DEAD :: 0
@(private = "file")
MATCHED :: 1

// The classes of the characters on either side of a place that the assertions read: none, at the text's start or
// end, a newline when a line anchor reads it, a word character when `\b` reads it, any other, and a newline that
// ends the text when `\Z` or a line anchor reads it.
@(private = "file")
EDGE :: 0
@(private = "file")
NEWLINE :: 1
@(private = "file")
WORD :: 2
@(private = "file")
OTHER :: 3
@(private = "file")
FINAL :: 4
@(private = "file")
CLASSES :: 5

Dfa :: struct {
	// Each state's row of `stride` entries: the start of the next state's row for each symbol, then for a newline that
	// ends the text, then for the text's end, where a state that matches there goes to the matched row.
	table:   []u32,
	stride:  u32,
	starts:  [CLASSES]u32, // the row a search starts in, by the class of the character before its start
	ascii:   [128]u8, // each ASCII character's symbol
	bounds:  []rune, // the first of each run of non-ASCII characters that share a symbol, from 0x80
	symbols: []u8, // the symbol of each run
	classes: []u8, // each symbol's class
	final:   u8, // the class of a newline that ends the text
	// The rows before `start_end` are the start rows, of the thread at the program's start alone, where a search may
	// skip to the next place a match can start: the next `prefix`, or with `leads` the next byte in `lead`. None are
	// when neither is known.
	start_end: u32,
	prefix:    string,
	leads:     bool,
	lead:      [4]u64,
	// The automaton that finds where the first match in the backtracker's order ends, in rows of the same stride, with
	// FIRST_ENDS on an entry when a match ends before the character it reads. Nil for a program it does not run.
	first:        []u32,
	first_starts: [CLASSES]u32,
	first_end:    u32, // the start rows of `first` come before it
	// The automaton read back from a match's end that finds where it starts, in rows of the same stride whose last
	// column is the text's start, with FIRST_ENDS on an entry when a match starts after the character it reads. By the
	// class of the character after the end. Nil when `first` is.
	last:        []u32,
	last_starts: [CLASSES]u32,
	// A program with no loop but a Rep's tries at most `choices` alternatives for each way through its two-way choices
	// and its Reps' counts, so a backtracker's retries at one start are bounded by the text left. -1 for one with a loop.
	choices, splits: int,
	reps:            []i32, // each Rep's counts, -1 for no bound
}

// On an entry of `Dfa.first`: a match ends where the character the entry reads begins.
@(private = "file")
FIRST_ENDS :: u32(1) << 31

// Whether `d`'s program matches in `s` at or after byte `start`, or judged false when the text holds a byte that does
// not begin a valid UTF-8 character there, or `start` is inside a character, where the backtracker's steps decide.
dfa_search :: proc(d: ^Dfa, s: string, start: int) -> (found: bool, judged: bool) {
	if start > len(s) {
		return false, true
	}
	before := EDGE
	if start > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:start])
		if w == 1 && s[start - 1] >= 0x80 || start < len(s) && s[start] & 0xC0 == 0x80 {
			return false, false
		}
		before = int(d.classes[d.ascii[r] if r < 0x80 else rune_symbol(d, r)])
		if start == len(s) && r == '\n' {
			before = int(d.final)
		}
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

// The row a whether search reaches from row `st` at byte `i` of `s` up to byte `end`, where it stops early on no match
// left or a match found. Under SKIP it jumps from a start row to the next place a match
// can start. Judged false as `dfa_search` is.
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

// Where the first match in the backtracker's order of `d`'s program at or after byte `start` in `s` ends, -1 for none,
// and the byte past the last character a thread read, which bounds every place the backtracker's search visits. Judged
// false as `dfa_search` is.
dfa_first :: proc(d: ^Dfa, s: string, start: int) -> (end, reach: int, judged: bool) {
	end = -1
	if start > len(s) {
		return -1, start, true
	}
	before := EDGE
	if start > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:start])
		if w == 1 && s[start - 1] >= 0x80 || start < len(s) && s[start] & 0xC0 == 0x80 {
			return -1, start, false
		}
		before = int(d.classes[d.ascii[r] if r < 0x80 else rune_symbol(d, r)])
		if start == len(s) && r == '\n' {
			before = int(d.final)
		}
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

// Where the match of `d`'s program that ends at byte `end` of `s` starts, the earliest place from byte `from` on that
// one does, -1 for none, judged false as `dfa_search` is.
dfa_start :: proc(d: ^Dfa, s: string, from, end: int) -> (start: int, judged: bool) {
	after := EDGE
	if end < len(s) {
		r, w := decode(s, end)
		if w == 1 && s[end] >= 0x80 || s[end] & 0xC0 == 0x80 {
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

// The next place from `i` where a match can start, `i` itself when nothing tells, or -1 for none. Only a program that
// cannot match empty has a prefix or lead bytes.
@(private = "file")
skip_to_lead :: #force_inline proc(d: ^Dfa, s: string, i: int) -> int {
	if d.prefix != "" {
		k := strings.index_byte(s[i:], d.prefix[0])
		return i + k if k >= 0 else -1
	}
	if !d.leads {
		return i
	}
	for j in i ..< len(s) {
		if d.lead[s[j] >> 6] & (1 << (u64(s[j]) & 63)) != 0 {
			return j
		}
	}
	return -1
}

// The class of the character before byte `i` of `s`, which starts a valid one past the text's start.
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

// What a character test of the program accepts: the ASCII characters as bits, and the non-ASCII ones as sorted runs
// that neither overlap nor touch.
@(private = "file")
Atom :: struct {
	ascii: [2]u64,
	runs:  [][2]rune,
}

// The atom of an item that is the program's Match.
@(private = "file")
MATCH_ITEM :: -1

@(private = "file")
Builder :: struct {
	re:           ^Regex,
	base:         []i32, // each instruction's first item, -1 for none
	atoms:        [dynamic]Atom,
	atom_ids:     map[string]i32, // each atom by the test it was made from
	key:          [dynamic]u8,
	item_pc:      [dynamic]i32,
	item_k:       [dynamic]i32, // a Rep's count or the character within a Str
	atom_of:      [dynamic]i32, // each item's atom, or MATCH_ITEM
	after:        [][]u32, // each reading item's threads after it reads
	// The items a thread at an instruction reaches before the next character, by the instruction and the classes
	// either side, Match among them.
	closures:     map[u32][]u32,
	lines:        bool, // the program has `^` or `$` of a line
	word:         bool, // the program has `\b` or `\B` of Unicode word characters
	ascii_word:   bool, // of ASCII ones
	semi_end:     bool, // the program has `\Z`, or `$` outside a multiline pattern
	empty_loops:  bool, // the program has a loop whose body can match empty
	keeps:        bool, // the program has `\K`
	asserts:      bool, // the program has an assertion, without which a closure reads no class
	used:         [CLASSES]bool, // the classes a character after a place can have, the text's end among them
	reads_before: bool, // an assertion past the text's start reads the class of the character before its place
	restart_dies: bool, // a thread at the program's start reaches nothing past the text's start
	stamp:        u32,
	in_set:       []u32, // the set that last took each thread
	walk:         u32,
	pc_seen:      []u32, // the closure that last reached each instruction
	item_seen:    []u32, // the closure that last took each item
	todo:         [dynamic]int,
	row_key:      [dynamic]u32,
	work:         int,
}

// Charges `steps` to the build's budget, false once it is spent.
@(private = "file")
charge :: #force_inline proc(b: ^Builder, steps: int) -> bool {
	b.work += steps
	return b.work <= DFA_MAX_WORK
}

// The states found so far: each one's threads with the class before them last, its row, and the table of their
// transitions.
@(private = "file")
States :: struct {
	ids:    map[string]u32,
	sets:   [dynamic][]u32, // in the order of their rows, past the dead and matched rows
	table:  [dynamic]u32,
	stride: u32,
}

// The automaton for `re`, in `allocator`, or nil when the program has an instruction it does not run or a cap is passed.
// The build's working memory comes from `scratch` and is freed before it returns.
build_dfa :: proc(re: ^Regex, allocator, scratch: mem.Allocator) -> ^Dfa {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, scratch, scratch, block_size = 8192, out_band_size = 2048)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)

	b := Builder{re = re}
	if !enumerate_items(&b) {
		return nil
	}
	n := len(b.atom_of)
	b.pc_seen = make([]u32, len(re.insts))
	b.item_seen = make([]u32, n)
	b.in_set = make([]u32, n + len(re.insts))
	b.after = make([][]u32, n)
	for i in 0 ..< n {
		if b.atom_of[i] != MATCH_ITEM {
			b.after[i] = after_read(&b, i)
		}
	}
	// The atoms of the classes the assertions read, which split the alphabet as an item's atom does.
	ok := charge(&b, n)
	newline, word := i32(-1), i32(-1)
	if ok && b.lines {
		newline, ok = rune_atom(&b, '\n')
	}
	if ok && (b.word || b.ascii_word) {
		word, ok = word_atom(&b, b.ascii_word)
	}
	ascii: [128]u8
	bounds: []rune
	symbols: []u8
	atom_syms: [][4]u64
	if ok {
		ascii, bounds, symbols, atom_syms, ok = alphabet(&b)
	}
	if !ok {
		return nil
	}
	syms := 0
	for s in symbols {
		syms = max(syms, int(s) + 1)
	}
	for s in ascii {
		syms = max(syms, int(s) + 1)
	}
	classes := make([]u8, syms)
	for &c, s in classes {
		takes :: proc(atom_syms: [][4]u64, atom: i32, s: int) -> bool {
			return atom >= 0 && atom_syms[atom][s >> 6] & (1 << (u64(s) & 63)) != 0
		}
		c = NEWLINE if takes(atom_syms, newline, s) else WORD if takes(atom_syms, word, s) else OTHER
	}
	newline_sym := int(ascii['\n'])
	final := u8(FINAL) if b.lines || b.semi_end else classes[newline_sym]
	b.used[EDGE], b.used[final] = true, true
	for c in classes {
		b.used[c] = true
	}
	stride := u32(syms + 2)

	st := States{stride = stride}
	resize(&st.table, 2 * int(stride))
	for k in 0 ..< int(stride) {
		st.table[int(stride) + k] = MATCHED * stride
	}
	// A search starts with one thread at the program's start, and adds one past each character it reads.
	restart := u32(n)
	b.restart_dies = true
	for before := NEWLINE; ok && b.restart_dies && before < CLASSES; before += 1 {
		for after := 0; ok && b.restart_dies && after < CLASSES; after += 1 {
			reach: []u32
			reach, ok = closure_of(&b, 0, before, after)
			b.restart_dies = len(reach) == 0
		}
	}
	starts: [CLASSES]u32
	for c := 0; ok && c < CLASSES; c += 1 {
		starts[c], ok = state_row(&b, &st, {restart}, c)
	}
	start_end := u32(len(st.table))
	bucket := make([dynamic]u32)
	for k := 0; ok && k < len(st.sets); k += 1 {
		set := st.sets[k]
		threads, before := set[:len(set) - 1], int(set[len(set) - 1])
		at := (2 + k) * int(stride)
		reached: [CLASSES][]u32
		matched: [CLASSES]bool
		for c := 0; ok && c < CLASSES; c += 1 {
			if !b.used[c] {
				continue
			}
			reached[c], matched[c], ok = expand(&b, threads, before, c)
		}
		for col := 0; ok && col <= syms; col += 1 {
			sym, c := col, int(classes[col]) if col < syms else int(final)
			if col == syms {
				sym = newline_sym
			}
			if matched[c] {
				st.table[at + col] = MATCHED * stride
				continue
			}
			if ok = charge(&b, 1 + len(reached[c])); !ok {
				break
			}
			b.stamp += 1
			clear(&bucket)
			for it in reached[c] {
				if atom_syms[b.atom_of[it]][sym >> 6] & (1 << (u64(sym) & 63)) == 0 {
					continue
				}
				if ok = charge(&b, len(b.after[it])); !ok {
					break
				}
				for x in b.after[it] {
					add_item(&b, &bucket, x)
				}
			}
			if !ok {
				break
			}
			add_item(&b, &bucket, restart)
			sort_keys(bucket[:])
			target: u32
			if target, ok = state_row(&b, &st, bucket[:], c); ok {
				st.table[at + col] = target
			}
		}
		st.table[at + syms + 1] = MATCHED * stride if matched[EDGE] else DEAD
	}
	if !ok {
		return nil
	}
	first, last: States
	first_starts, last_starts: [CLASSES]u32
	first_end: u32
	// Oniguruma ends an empty iteration by where it began, which the threads of a position do not hold.
	has_first := !re.ecma && !b.empty_loops && !b.keeps
	if has_first {
		first, first_starts, first_end, has_first = build_first(&b, classes, final, syms, newline_sym, atom_syms)
	}
	if has_first {
		last, last_starts, has_first = build_last(&b, classes, final, syms, newline_sym, atom_syms)
	}

	context.allocator = allocator
	d := new(Dfa)
	d^ = {
		table   = slice.clone(st.table[:]),
		stride  = stride,
		starts  = starts,
		ascii   = ascii,
		bounds  = slice.clone(bounds),
		symbols = slice.clone(symbols),
		classes = slice.clone(classes),
		final   = final,
		start_end = start_end,
		prefix  = re.prefix,
		leads   = re.has_first,
		lead    = re.first,
	}
	if has_first {
		d.first, d.first_starts, d.first_end = slice.clone(first.table[:]), first_starts, first_end
		d.last, d.last_starts = slice.clone(last.table[:]), last_starts
	}
	// With nothing to skip to, no row is a start row, so the search does not stop at each byte to look.
	if d.prefix == "" && !d.leads {
		d.start_end, d.first_end = 0, 0
	}
	reps := make([dynamic]i32)
	loops: for ins, pc in re.insts {
		#partial switch ins.op {
		case .Split, .Split_Head:
			if int(ins.a) < pc || int(ins.b) < pc {
				d.choices = -1
				break loops
			}
			d.choices += 1
			d.splits += 1
		case .Jmp:
			if int(ins.a) < pc {
				d.choices = -1
				break loops
			}
		case .Rep, .Rep_Lazy:
			if ins.a != ins.b {
				d.choices += 1
				append(&reps, -1 if ins.b < 0 else ins.b - ins.a + 1)
			}
		}
	}
	d.reps = reps[:]
	return d
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

// The automaton of the first match in the backtracker's order. A state is the threads after the characters read so far
// in the order the backtracker tries them, with the class of the last character and whether a match has ended, so it
// runs the backtracker's search on every path at once: a thread that reaches Match ends a match there and drops every
// thread after it, which the backtracker would try only had that match failed, and the thread at the program's start
// that each character adds comes last and only until a match has ended. The match the search last sees end is the
// backtracker's: at the earliest start that has one, the first in its order to end.
@(private = "file")
build_first :: proc(b: ^Builder, classes: []u8, final: u8, syms, newline_sym: int, atom_syms: [][4]u64) -> (st: States, starts: [CLASSES]u32, first_end: u32, ok: bool) {
	n := len(b.atom_of)
	stride := u32(syms + 2)
	st.stride = stride
	resize(&st.table, int(stride))
	restart := u32(n)
	for c in 0 ..< CLASSES {
		starts[c] = first_row(b, &st, {restart}, c, false) or_return
	}
	first_end = u32(len(st.table))
	bucket := make([dynamic]u32)
	for k := 0; k < len(st.sets); k += 1 {
		set := st.sets[k]
		threads, before, ended := set[:len(set) - 1], int(set[len(set) - 1] & 0xFF), set[len(set) - 1] >> 8 != 0
		at := (1 + k) * int(stride)
		reached: [CLASSES][]u32
		matched: [CLASSES]bool
		for c in 0 ..< CLASSES {
			if !b.used[c] {
				continue
			}
			reached[c], matched[c] = expand_first(b, threads, before, c) or_return
		}
		for col in 0 ..= syms {
			sym, c := col, int(classes[col]) if col < syms else int(final)
			if col == syms {
				sym = newline_sym
			}
			charge(b, 1 + len(reached[c])) or_return
			b.stamp += 1
			clear(&bucket)
			for it in reached[c] {
				if atom_syms[b.atom_of[it]][sym >> 6] & (1 << (u64(sym) & 63)) == 0 {
					continue
				}
				charge(b, len(b.after[it])) or_return
				for x in b.after[it] {
					add_item(b, &bucket, x)
				}
			}
			now_ended := ended || matched[c]
			if !now_ended {
				add_item(b, &bucket, restart)
			}
			target := first_row(b, &st, bucket[:], c, now_ended) or_return
			st.table[at + col] = target | (FIRST_ENDS if matched[c] else 0)
		}
		st.table[at + syms + 1] = FIRST_ENDS if matched[EDGE] else DEAD
	}
	return st, starts, first_end, true
}

// The row of the state of `threads` in their order after a character of class `read`, with whether a match has ended,
// a new state queued when none has it, or false past a cap. A thread whose closure reaches nothing whatever comes next
// is left out, and so is the thread at the program's start when it reaches nothing past the text's start, so a state
// with no thread left is the dead row.
@(private = "file")
first_row :: proc(b: ^Builder, st: ^States, threads: []u32, read: int, ended: bool) -> (row: u32, ok: bool) {
	before := seen_class(b, read)
	n := len(b.atom_of)
	clear(&b.row_key)
	for x in threads {
		if int(x) >= n && (int(x) > n || b.restart_dies) {
			live := false
			for c := 0; !live && c < CLASSES; c += 1 {
				reach := closure_of(b, int(x) - n, before, c) or_return
				live = len(reach) > 0
			}
			if !live {
				continue
			}
		}
		append(&b.row_key, x)
	}
	if len(b.row_key) == 0 {
		return DEAD, true
	}
	append(&b.row_key, u32(before) | u32(ended) << 8)
	key := b.row_key[:]
	if known, seen := st.ids[string(slice.to_bytes(key))]; seen {
		return known, true
	}
	stride := int(st.stride)
	if len(st.sets) >= DFA_MAX_STATES || len(st.table) + stride > DFA_MAX_TABLE || !charge(b, len(key) + stride) {
		return 0, false
	}
	owned := slice.clone(key)
	row = u32(len(st.table))
	st.ids[string(slice.to_bytes(owned))] = row
	append(&st.sets, owned)
	if len(st.table) + stride > cap(st.table) {
		reserve(&st.table, max(2 * cap(st.table), len(st.table) + stride))
	}
	resize(&st.table, len(st.table) + stride)
	return row, true
}

// The automaton read back from a match's end. A state is the items that, at the place it has read back to, read on to
// the end and Match there, with the class of the character after that place. An item is in it after a character when
// it reads that character and one item its next threads reach is in the state before, and a match starts at a place
// when the program's start reaches one of the state's items there.
@(private = "file")
build_last :: proc(b: ^Builder, classes: []u8, final: u8, syms, newline_sym: int, atom_syms: [][4]u64) -> (st: States, starts: [CLASSES]u32, ok: bool) {
	n := len(b.atom_of)
	stride := u32(syms + 2)
	st.stride = stride
	resize(&st.table, int(stride))
	ends := make([dynamic]u32)
	for it in 0 ..< n {
		if b.atom_of[it] == MATCH_ITEM {
			append(&ends, u32(it))
		}
	}
	for c in 0 ..< CLASSES {
		starts[c] = last_row(b, &st, ends[:], c) or_return
	}
	bucket := make([dynamic]u32)
	for k := 0; k < len(st.sets); k += 1 {
		set := st.sets[k]
		items, after := set[:len(set) - 1], int(set[len(set) - 1])
		at := (1 + k) * int(stride)
		b.stamp += 1
		for it in items {
			b.in_set[it] = b.stamp
		}
		mark := b.stamp
		// For each class of the character read back, the items whose next threads reach the state, and whether the
		// program's start does.
		reading: [CLASSES][]u32
		starts_here: [CLASSES + 1]bool
		for c in 0 ..< CLASSES {
			if !b.used[c] {
				continue
			}
			found := make([dynamic]u32)
			for it in 0 ..< n {
				if b.atom_of[it] == MATCH_ITEM {
					continue
				}
				charge(b, 1 + len(b.after[it])) or_return
				hit := false
				for x in b.after[it] {
					if int(x) < n {
						hit = b.in_set[x] == mark
					} else {
						reach := closure_of(b, int(x) - n, c, after) or_return
						charge(b, len(reach)) or_return
						for y in reach {
							if hit = b.in_set[y] == mark; hit {
								break
							}
						}
					}
					if hit {
						break
					}
				}
				if hit {
					append(&found, u32(it))
				}
			}
			reading[c] = found[:]
			reach := closure_of(b, 0, c, after) or_return
			for y in reach {
				starts_here[c] ||= b.in_set[y] == mark
			}
		}
		for col in 0 ..= syms {
			sym, c := col, int(classes[col]) if col < syms else int(final)
			if col == syms {
				sym = newline_sym
			}
			charge(b, 1 + len(reading[c])) or_return
			clear(&bucket)
			for it in reading[c] {
				if atom_syms[b.atom_of[it]][sym >> 6] & (1 << (u64(sym) & 63)) != 0 {
					append(&bucket, it)
				}
			}
			target := last_row(b, &st, bucket[:], c) or_return
			st.table[at + col] = target | (FIRST_ENDS if starts_here[c] else 0)
		}
		st.table[at + syms + 1] = FIRST_ENDS if starts_here[EDGE] else DEAD
	}
	return st, starts, true
}

// The row of the state of sorted `items` before a character of class `after`, a new state queued when none has it, or
// false past a cap. A state with no item is the dead row.
@(private = "file")
last_row :: proc(b: ^Builder, st: ^States, items: []u32, after: int) -> (row: u32, ok: bool) {
	if len(items) == 0 {
		return DEAD, true
	}
	clear(&b.row_key)
	append(&b.row_key, ..items)
	append(&b.row_key, u32(after))
	key := b.row_key[:]
	if known, seen := st.ids[string(slice.to_bytes(key))]; seen {
		return known, true
	}
	stride := int(st.stride)
	if len(st.sets) >= DFA_MAX_STATES || len(st.table) + stride > DFA_MAX_TABLE || !charge(b, len(key) + stride) {
		return 0, false
	}
	owned := slice.clone(key)
	row = u32(len(st.table))
	st.ids[string(slice.to_bytes(owned))] = row
	append(&st.sets, owned)
	if len(st.table) + stride > cap(st.table) {
		reserve(&st.table, max(2 * cap(st.table), len(st.table) + stride))
	}
	resize(&st.table, len(st.table) + stride)
	return row, true
}

// The reading items `threads` reach in their order between a character of class `before` and one of class `after`, up
// to the first that reaches Match, and whether one does.
@(private = "file")
expand_first :: proc(b: ^Builder, threads: []u32, before, after: int) -> (items: []u32, matched: bool, ok: bool) {
	n := len(b.atom_of)
	b.stamp += 1
	set := make([dynamic]u32)
	walk: for x in threads {
		if int(x) < n {
			add_item(b, &set, x)
			continue
		}
		reach := closure_of(b, int(x) - n, before, after) or_return
		charge(b, len(reach)) or_return
		for it in reach {
			if b.atom_of[it] == MATCH_ITEM {
				matched = true
				break walk
			}
			add_item(b, &set, it)
		}
	}
	return set[:], matched, true
}

// The class of the character before a place as the program's assertions tell it from the others.
@(private = "file")
seen_class :: proc(b: ^Builder, c: int) -> int {
	switch {
	case c == EDGE:
		return EDGE
	case !b.reads_before, c == NEWLINE && !b.lines, c == FINAL && !b.lines, c == WORD && !b.word && !b.ascii_word:
		return OTHER
	}
	return c
}

// The row of the state of `threads` after a character of class `read`, a new state queued for its transitions when
// none has them, or false past a cap. A thread at an instruction whose closure reaches nothing whatever comes next is
// left out, and the thread at the program's start that each character adds is left out only when it reaches nothing
// anywhere past the text's start, so a state with no thread left is the dead row.
@(private = "file")
state_row :: proc(b: ^Builder, st: ^States, threads: []u32, read: int) -> (row: u32, ok: bool) {
	before := seen_class(b, read)
	n := len(b.atom_of)
	clear(&b.row_key)
	for x in threads {
		if int(x) >= n && (int(x) > n || b.restart_dies) {
			live := false
			for c := 0; !live && c < CLASSES; c += 1 {
				reach := closure_of(b, int(x) - n, before, c) or_return
				live = len(reach) > 0
			}
			if !live {
				continue
			}
		}
		append(&b.row_key, x)
	}
	if len(b.row_key) == 0 {
		return DEAD, true
	}
	append(&b.row_key, u32(before))
	key := b.row_key[:]
	if known, seen := st.ids[string(slice.to_bytes(key))]; seen {
		return known, true
	}
	stride := int(st.stride)
	if len(st.sets) >= DFA_MAX_STATES || len(st.table) + stride > DFA_MAX_TABLE || !charge(b, len(key) + stride) {
		return 0, false
	}
	owned := slice.clone(key)
	row = u32(len(st.table))
	st.ids[string(slice.to_bytes(owned))] = row
	append(&st.sets, owned)
	// The table grows by doubling, so the copies it leaves in the arena add up to no more than its final size.
	if len(st.table) + stride > cap(st.table) {
		reserve(&st.table, max(2 * cap(st.table), len(st.table) + stride))
	}
	resize(&st.table, len(st.table) + stride)
	return row, true
}

// Gives each place the program reads a character at an item: a Str one per character, a one-character test one, a
// Rep one per count it can read at (a count past the least, of an unbounded Rep, counted as the least), and Match one.
// False for a program the automaton does not run.
@(private = "file")
enumerate_items :: proc(b: ^Builder) -> bool {
	re := b.re
	insts := re.insts
	b.base = make([]i32, len(insts))
	slice.fill(b.base, -1)
	rep_body := false
	for ins, pc in insts {
		if rep_body {
			rep_body = false
			continue
		}
		first := i32(len(b.atom_of))
		#partial switch ins.op {
		case .Match:
			add_items(b, pc, 1, MATCH_ITEM)
		case .Assert:
			b.asserts = true
			#partial switch Assert_Kind(ins.a) {
			case .Begin_Buf, .End_Buf:
			case .Semi_End_Buf:
				b.semi_end = true
			case .Begin_Line, .End_Line:
				b.lines, b.reads_before = true, true
			case .Word_Boundary, .Not_Word_Boundary:
				b.word, b.reads_before = true, true
			case .Ascii_Boundary, .Not_Ascii_Boundary:
				b.ascii_word, b.reads_before = true, true
			case:
				return false
			}
			continue
		case .Str:
			lit := re.bytes[ins.a:][:ins.b]
			if len(lit) > DFA_MAX_ITEMS * utf8.UTF_MAX {
				return false
			}
			k := 0
			for r in lit {
				atom := rune_atom(b, r) or_return
				add_items(b, pc, 1, atom, k)
				k += 1
			}
		case .Class, .Any, .Any_All, .Char_Fold:
			atom := inst_atom(b, ins) or_return
			add_items(b, pc, 1, atom)
		case .Rep, .Rep_Lazy:
			atom := inst_atom(b, insts[pc + 1]) or_return
			count := int(ins.a) + 1 if ins.b < 0 else int(ins.b)
			if count > DFA_MAX_ITEMS {
				return false
			}
			add_items(b, pc, count, atom)
			rep_body = true
		case .Check:
			b.empty_loops = true
			continue
		case .Save:
			b.keeps ||= ins.a == 0
			continue
		case .Split, .Split_Head, .Jmp, .Set, .Unset:
			continue
		case:
			return false
		}
		b.base[pc] = first
		if len(b.atom_of) > DFA_MAX_ITEMS {
			return false
		}
	}
	return !(b.word && b.ascii_word)
}

@(private = "file")
add_items :: proc(b: ^Builder, pc, count: int, atom: i32, k := 0) {
	for j in 0 ..< count {
		append(&b.item_pc, i32(pc))
		append(&b.item_k, i32(k + j))
		append(&b.atom_of, atom)
	}
}

// The atom of a one-character test, false for a test the automaton does not run.
@(private = "file")
inst_atom :: proc(b: ^Builder, ins: Inst) -> (i32, bool) {
	#partial switch ins.op {
	case .Class:
		return class_atom(b, b.re.classes[ins.a])
	case .Str:
		r, w := utf8.decode_rune_in_string(b.re.bytes[ins.a:][:ins.b])
		if w != int(ins.b) {
			return 0, false
		}
		return rune_atom(b, r)
	case .Any, .Any_All:
		clear(&b.key)
		append(&b.key, 'a' if ins.op == .Any else 'A')
		if at, seen := b.atom_ids[string(b.key[:])]; seen {
			return at, true
		}
		a := Atom{ascii = {max(u64), max(u64)}, runs = slice.clone([][2]rune{{0x80, utf8.MAX_RUNE}})}
		if ins.op == .Any {
			a.ascii[0] &~= 1 << '\n'
		}
		return add_atom(b, a)
	case .Char_Fold:
		return fold_atom(b, rune(ins.a))
	}
	return 0, false
}

@(private = "file")
rune_atom :: proc(b: ^Builder, r: rune) -> (i32, bool) {
	clear(&b.key)
	x := transmute([4]u8)r
	append(&b.key, 'r')
	append(&b.key, ..x[:])
	if at, seen := b.atom_ids[string(b.key[:])]; seen {
		return at, true
	}
	a: Atom
	if r < 0x80 {
		a.ascii[r >> 6] = 1 << (u64(r) & 63)
	} else {
		a.runs = slice.clone([][2]rune{{r, r}})
	}
	return add_atom(b, a)
}

// The atom of the characters whose case fold is `f`: those that fold alike with it.
@(private = "file")
fold_atom :: proc(b: ^Builder, f: rune) -> (i32, bool) {
	clear(&b.key)
	x := transmute([4]u8)f
	append(&b.key, 'f')
	append(&b.key, ..x[:])
	if at, seen := b.atom_ids[string(b.key[:])]; seen {
		return at, true
	}
	a: Atom
	runs := make([dynamic][2]rune)
	take :: proc(a: ^Atom, runs: ^[dynamic][2]rune, f, r: rune) {
		switch {
		case fold(r) != f:
		case r < 0x80:
			a.ascii[r >> 6] |= 1 << (u64(r) & 63)
		case:
			append(runs, [2]rune{r, r})
		}
	}
	take(&a, &runs, f, f)
	if f >= 'a' && f <= 'z' {
		take(&a, &runs, f, f - 32)
	}
	for r := fold_next(f); r != f; r = fold_next(r) {
		if !charge(b, 1) {
			return 0, false
		}
		take(&a, &runs, f, r)
	}
	a.runs = merge_runs(runs[:])
	return add_atom(b, a)
}

// The atom of the word characters `\b` reads, of ASCII alone or of Unicode.
@(private = "file")
word_atom :: proc(b: ^Builder, ascii_only: bool) -> (id: i32, ok: bool) {
	clear(&b.key)
	append(&b.key, 'w', u8(ascii_only))
	a: Atom
	for r in rune(0) ..< 0x80 {
		if is_word(r) {
			a.ascii[r >> 6] |= 1 << (u64(r) & 63)
		}
	}
	if !ascii_only {
		runs := make([dynamic][2]rune)
		table_runs(b, &runs, TABLE_WORD, 0x80) or_return
		a.runs = merge_runs(runs[:])
	}
	return add_atom(b, a)
}

// Appends the runs of property table `t` from `floor` on, charged.
@(private = "file")
table_runs :: proc(b: ^Builder, runs: ^[dynamic][2]rune, t: int, floor: rune) -> bool {
	entries := PROPERTY_RANGES[PROPERTY_TABLES[t]:PROPERTY_TABLES[t + 1]]
	if !charge(b, len(entries)) {
		return false
	}
	for e in entries {
		lo := rune(e >> RANGE_SPAN_BITS)
		hi := lo + rune(e & (1 << RANGE_SPAN_BITS - 1))
		if hi >= floor {
			append(runs, [2]rune{max(lo, floor), hi})
		}
	}
	return true
}

// The atom of class `cls`, one for every class that names the same ranges, properties and folding, false for a class
// that reads a table the automaton does not.
@(private = "file")
class_atom :: proc(b: ^Builder, cls: ^Class) -> (id: i32, ok: bool) {
	clear(&b.key)
	count := transmute([4]u8)u32(len(cls.ranges))
	append(&b.key, 'c', u8(cls.negated) | u8(cls.fold) << 1)
	append(&b.key, ..count[:])
	for g in cls.ranges {
		x := transmute([8]u8)g
		append(&b.key, ..x[:])
	}
	for it in cls.props {
		if int(it.table) == TABLE_GCB_EXTEND {
			return 0, false
		}
		x := transmute([4]u8)(u32(it.table) << 1 | u32(it.neg))
		append(&b.key, ..x[:])
	}
	if !charge(b, len(b.key)) {
		return 0, false
	}
	if at, seen := b.atom_ids[string(b.key[:])]; seen {
		return at, true
	}
	// A folding class takes a character when one it folds alike with is in the class, so its ASCII ones count too.
	floor := rune(0) if cls.fold else 0x80
	runs := make([dynamic][2]rune)
	for g in cls.ranges {
		if g[1] >= floor {
			append(&runs, [2]rune{max(g[0], floor), g[1]})
		}
	}
	for it in cls.props {
		from := len(runs)
		t := int(it.table)
		table_runs(b, &runs, TABLE_WORD if t == TABLE_CLASS_WORD else t, floor) or_return
		if t == TABLE_CLASS_WORD {
			// In a class `\w` lacks the digits ²³¹ and the fractions ¼½¾.
			cut := complement_runs(merge_runs(runs[from:]), floor)
			append(&cut, [2]rune{0xB2, 0xB3}, [2]rune{0xB9, 0xB9}, [2]rune{0xBC, 0xBE})
			kept := complement_runs(merge_runs(cut[:]), floor)
			resize(&runs, from)
			append(&runs, ..kept[:])
		}
		if it.neg {
			flipped := complement_runs(merge_runs(runs[from:]), floor)
			resize(&runs, from)
			append(&runs, ..flipped[:])
		}
	}
	if !charge(b, len(runs)) {
		return 0, false
	}
	merged := merge_runs(runs[:])
	if cls.fold {
		merged = fold_runs(b, merged) or_return
		k := 0
		for k < len(merged) && merged[k][1] < 0x80 {
			k += 1
		}
		merged = merged[k:]
		if len(merged) > 0 && merged[0][0] < 0x80 {
			merged[0][0] = 0x80
		}
	}
	return add_atom(b, {ascii = cls.ascii, runs = complement_runs(merged, 0x80)[:] if cls.negated else merged})
}

// `runs`, sorted and merged, with every character that folds alike with one in them.
@(private = "file")
fold_runs :: proc(b: ^Builder, runs: [][2]rune) -> ([][2]rune, bool) {
	out := make([dynamic][2]rune)
	append(&out, ..runs)
	for g in runs {
		lo, n := 0, len(FOLDS)
		for n > 0 {
			half := n >> 1
			if rune(FOLDS[lo + half] >> (2 * FOLD_BITS)) < g[0] {
				lo, n = lo + half + 1, n - half - 1
			} else {
				n = half
			}
		}
		for k := lo; k < len(FOLDS) && rune(FOLDS[k] >> (2 * FOLD_BITS)) <= g[1]; k += 1 {
			c := rune(FOLDS[k] >> (2 * FOLD_BITS))
			for r := fold_next(c); r != c; r = fold_next(r) {
				if !charge(b, 1) {
					return nil, false
				}
				append(&out, [2]rune{r, r})
			}
		}
	}
	return merge_runs(out[:]), true
}

// Records atom `a` under the key being built.
@(private = "file")
add_atom :: proc(b: ^Builder, a: Atom) -> (i32, bool) {
	at := i32(len(b.atoms))
	append(&b.atoms, a)
	b.atom_ids[string(slice.clone(b.key[:]))] = at
	return at, true
}

// `runs` sorted, with the runs that overlap or touch joined, in place.
@(private = "file")
merge_runs :: proc(runs: [][2]rune) -> [][2]rune {
	keys := make([]u64, len(runs))
	for g, i in runs {
		keys[i] = u64(g[0]) << 32 | u64(g[1])
	}
	sort_keys(keys)
	for k, i in keys {
		runs[i] = {rune(k >> 32), rune(u32(k))}
	}
	n := 0
	for g in runs {
		if n > 0 && g[0] <= runs[n - 1][1] + 1 {
			runs[n - 1][1] = max(runs[n - 1][1], g[1])
			continue
		}
		runs[n] = g
		n += 1
	}
	return runs[:n]
}

// The characters from `floor` on that sorted runs `runs` leave out, as runs.
@(private = "file")
complement_runs :: proc(runs: [][2]rune, floor: rune) -> [dynamic][2]rune {
	out := make([dynamic][2]rune, 0, len(runs) + 1)
	lo := floor
	for g in runs {
		if g[0] > lo {
			append(&out, [2]rune{lo, g[0] - 1})
		}
		lo = max(lo, g[1] + 1)
	}
	if lo <= utf8.MAX_RUNE {
		append(&out, [2]rune{lo, utf8.MAX_RUNE})
	}
	return out
}

// Sorts `keys` by insertion when they are few, by merging their sorted stretches when there are few of those, as when
// they join lists each sorted, and otherwise by radix on bytes, passing over a byte every key shares.
@(private = "file")
sort_keys :: proc(keys: $S/[]$T) {
	if len(keys) <= 32 {
		for i in 1 ..< len(keys) {
			x, j := keys[i], i
			for j > 0 && keys[j - 1] > x {
				keys[j] = keys[j - 1]
				j -= 1
			}
			keys[j] = x
		}
		return
	}
	descents := 0
	for i in 1 ..< len(keys) {
		descents += int(keys[i - 1] > keys[i])
	}
	if descents == 0 {
		return
	}
	from, to := keys, make([]T, len(keys))
	if descents <= 16 {
		bounds := make([dynamic]int, 0, descents + 2)
		append(&bounds, 0)
		for i in 1 ..< len(keys) {
			if keys[i - 1] > keys[i] {
				append(&bounds, i)
			}
		}
		append(&bounds, len(keys))
		for len(bounds) > 2 {
			n := 0
			for j := 0; j + 1 < len(bounds); j += 2 {
				lo, mid := bounds[j], bounds[j + 1]
				hi := bounds[j + 2] if j + 2 < len(bounds) else mid
				a, c, k := lo, mid, lo
				for a < mid && c < hi {
					if from[c] < from[a] {
						to[k], c = from[c], c + 1
					} else {
						to[k], a = from[a], a + 1
					}
					k += 1
				}
				k += copy(to[k:], from[a:mid])
				copy(to[k:], from[c:hi])
				bounds[n] = lo
				n += 1
			}
			bounds[n] = len(keys)
			resize(&bounds, n + 1)
			from, to = to, from
		}
		if raw_data(from) != raw_data(keys) {
			copy(keys, from)
		}
		return
	}
	for shift := uint(0); shift < 8 * size_of(T); shift += 8 {
		counts: [257]int
		for k in from {
			counts[(k >> shift) & 0xFF + 1] += 1
		}
		if counts[(from[0] >> shift) & 0xFF + 1] == len(from) {
			continue
		}
		for i in 1 ..< len(counts) {
			counts[i] += counts[i - 1]
		}
		for k in from {
			d := (k >> shift) & 0xFF
			to[counts[d]] = k
			counts[d] += 1
		}
		from, to = to, from
	}
	if raw_data(from) != raw_data(keys) {
		copy(keys, from)
	}
}

@(private = "file")
add_item :: #force_inline proc(b: ^Builder, set: ^[dynamic]u32, it: u32) {
	if b.in_set[it] != b.stamp {
		b.in_set[it] = b.stamp
		append(set, it)
	}
}

// Whether assertion `kind` holds between a character of class `before` and one of class `after`.
@(private = "file")
holds :: proc(kind: Assert_Kind, before, after: int) -> bool {
	#partial switch kind {
	case .Begin_Buf:
		return before == EDGE
	case .End_Buf:
		return after == EDGE
	case .Semi_End_Buf:
		return after == EDGE || after == FINAL
	case .Begin_Line:
		// Oniguruma's `^` does not hold after a newline that ends the text.
		return before == EDGE || before == NEWLINE
	case .End_Line:
		return after == EDGE || after == NEWLINE || after == FINAL
	case .Word_Boundary, .Ascii_Boundary:
		return (before == WORD) != (after == WORD)
	case .Not_Word_Boundary, .Not_Ascii_Boundary:
		return (before == WORD) == (after == WORD)
	}
	return false
}

// The items, Match among them, that a thread at instruction `pc` reaches between a character of class `before` and one
// of class `after`, by the instructions that read nothing, each charged as it is visited.
@(private = "file")
closure_of :: proc(b: ^Builder, pc, before, after: int) -> ([]u32, bool) {
	before, after := before, after
	if !b.asserts {
		before, after = 0, 0
	}
	key := u32((pc * CLASSES + before) * CLASSES + after)
	if reach, seen := b.closures[key]; seen {
		return reach, true
	}
	insts := b.re.insts
	b.walk += 1
	set := make([dynamic]u32)
	take :: #force_inline proc(b: ^Builder, set: ^[dynamic]u32, it: i32) {
		if b.item_seen[it] != b.walk {
			b.item_seen[it] = b.walk
			append(set, u32(it))
		}
	}
	// The instructions are visited in the order of their alternatives, so the items come out in it. An entry past the
	// program is a lazy Rep's first item, taken after its exit.
	clear(&b.todo)
	append(&b.todo, pc)
	for len(b.todo) > 0 {
		at := pop(&b.todo)
		if at >= len(insts) {
			take(b, &set, b.base[at - len(insts)])
			continue
		}
		if b.pc_seen[at] == b.walk {
			continue
		}
		b.pc_seen[at] = b.walk
		if !charge(b, 1) {
			return nil, false
		}
		ins := insts[at]
		#partial switch ins.op {
		case .Match, .Str, .Class, .Any, .Any_All, .Char_Fold:
			take(b, &set, b.base[at])
		case .Assert:
			if holds(Assert_Kind(ins.a), before, after) {
				append(&b.todo, at + 1)
			}
		case .Split:
			append(&b.todo, int(ins.b), int(ins.a))
		case .Split_Head:
			append(&b.todo, int(ins.b), at + 1)
		case .Jmp:
			append(&b.todo, int(ins.a))
		case .Save, .Set, .Unset, .Check:
			// An empty iteration that Check ends or fails is a path the loop's exit already takes.
			append(&b.todo, at + 1)
		case .Rep:
			if ins.b != 0 {
				take(b, &set, b.base[at])
			}
			if ins.a == 0 {
				append(&b.todo, at + 2)
			}
		case .Rep_Lazy:
			if ins.b != 0 {
				append(&b.todo, len(insts) + at)
			}
			if ins.a == 0 {
				append(&b.todo, at + 2)
			}
		}
	}
	b.closures[key] = set[:]
	return set[:], true
}

// The reading items `threads` reach between a character of class `before` and one of class `after`, and whether
// Match is among what they reach.
@(private = "file")
expand :: proc(b: ^Builder, threads: []u32, before, after: int) -> (items: []u32, matched: bool, ok: bool) {
	n := len(b.atom_of)
	b.stamp += 1
	set := make([dynamic]u32)
	for x in threads {
		if int(x) < n {
			add_item(b, &set, x)
			continue
		}
		reach := closure_of(b, int(x) - n, before, after) or_return
		charge(b, len(reach)) or_return
		for it in reach {
			if b.atom_of[it] == MATCH_ITEM {
				matched = true
			} else {
				add_item(b, &set, it)
			}
		}
	}
	return set[:], matched, true
}

// The threads after reading item `it`'s character, in the order of their alternatives: the item after it, or a thread
// at the instruction it goes on to.
@(private = "file")
after_read :: proc(b: ^Builder, it: int) -> []u32 {
	n := len(b.atom_of)
	pc, k := int(b.item_pc[it]), int(b.item_k[it])
	ins := b.re.insts[pc]
	out := make([dynamic]u32, 0, 2)
	#partial switch ins.op {
	case .Str:
		if it + 1 < n && int(b.item_pc[it + 1]) == pc {
			append(&out, u32(it + 1))
		} else {
			append(&out, u32(n + pc + 1))
		}
	case .Rep, .Rep_Lazy:
		count := k + 1
		if ins.b < 0 {
			count = min(count, int(ins.a))
		}
		if ins.b < 0 || count < int(ins.b) {
			append(&out, u32(int(b.base[pc]) + count))
		}
		if count >= int(ins.a) {
			append(&out, u32(n + pc + 2))
			if ins.op == .Rep_Lazy && len(out) == 2 {
				out[0], out[1] = out[1], out[0]
			}
		}
	case:
		append(&out, u32(n + pc + 1))
	}
	return out[:]
}

// The symbols: characters every atom answers alike for share one. The ASCII characters' symbols, the runs of non-ASCII
// characters with theirs, and for each atom the symbols it accepts. False past the symbol cap or the budget.
@(private = "file")
alphabet :: proc(b: ^Builder) -> (ascii: [128]u8, bounds: []rune, symbols: []u8, atom_syms: [][4]u64, ok: bool) {
	n := len(b.atoms)
	ids := make(map[string]u8)
	atom_syms = make([][4]u64, n)
	// The atoms that accept the characters being given a symbol, one bit each.
	accepting := make([]u64, max((n + 63) / 64, 1))
	symbol :: proc(b: ^Builder, ids: ^map[string]u8, atom_syms: [][4]u64, accepting: []u64) -> (u8, bool) {
		if !charge(b, len(accepting)) {
			return 0, false
		}
		if s, seen := ids[string(slice.to_bytes(accepting))]; seen {
			return s, true
		}
		if len(ids) >= DFA_MAX_SYMBOLS || !charge(b, len(atom_syms)) {
			return 0, false
		}
		s := u8(len(ids))
		ids[string(slice.to_bytes(slice.clone(accepting)))] = s
		for a in 0 ..< len(atom_syms) {
			if accepting[a >> 6] & (1 << (u64(a) & 63)) != 0 {
				atom_syms[a][s >> 6] |= 1 << (u64(s) & 63)
			}
		}
		return s, true
	}
	if !charge(b, 128 * n) {
		return
	}
	for r in 0 ..< 128 {
		slice.zero(accepting)
		for a, i in b.atoms {
			if a.ascii[r >> 6] & (1 << (u64(r) & 63)) != 0 {
				accepting[i >> 6] |= 1 << (u64(i) & 63)
			}
		}
		ascii[r] = symbol(b, &ids, atom_syms, accepting) or_return
	}
	// Past ASCII an atom's answer changes only where one of its runs begins or ends, so a sweep over those places in
	// order meets each run of characters every atom answers alike once.
	// Each edge is the character it falls on above the atom it turns on or off, which takes the low ATOM_BITS.
	ATOM_BITS :: 11
	#assert(DFA_MAX_ITEMS <= 1 << ATOM_BITS && utf8.MAX_RUNE < 1 << (32 - ATOM_BITS))
	if n > 1 << ATOM_BITS {
		return
	}
	edges := make([dynamic]u32)
	for a, i in b.atoms {
		if !charge(b, len(a.runs)) {
			return
		}
		for g in a.runs {
			append(&edges, u32(g[0]) << ATOM_BITS | u32(i))
			if g[1] < utf8.MAX_RUNE {
				append(&edges, u32(g[1] + 1) << ATOM_BITS | u32(i))
			}
		}
	}
	sort_keys(edges[:])
	runs := make([dynamic]rune)
	syms := make([dynamic]u8)
	slice.zero(accepting)
	at, k := rune(0x80), 0
	for {
		// An atom's runs neither overlap nor touch, so each edge turns its atom on or off.
		for k < len(edges) && rune(edges[k] >> ATOM_BITS) == at {
			i := edges[k] & (1 << ATOM_BITS - 1)
			accepting[i >> 6] ~= 1 << (u64(i) & 63)
			k += 1
		}
		s := symbol(b, &ids, atom_syms, accepting) or_return
		if len(syms) == 0 || syms[len(syms) - 1] != s {
			append(&runs, at)
			append(&syms, s)
		}
		if k == len(edges) {
			break
		}
		at = rune(edges[k] >> ATOM_BITS)
	}
	return ascii, runs[:], syms[:], atom_syms, true
}
