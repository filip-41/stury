#+private
package regex

// The subset construction of the automaton in dfa.odin.
//
// A state is the program's threads after the characters read so far, with the class of the last character. A thread is
// a reading item, or an instruction whose closure is still to be followed. An assertion reads the class of the
// character after its place, so closures are followed as the next symbol is read, whose class the table knows.
//
// Every step of the build is charged to a single budget (`Builder.work`) and the build gives up past DFA_MAX_WORK. So
// its time and working memory are bounded by the budget and the program's length whatever the pattern. The working
// memory is freed before the build returns and only the automaton is kept.

import "core:mem"
import "core:slice"
import "core:unicode/utf8"

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
	// The items a thread at an instruction reaches before the next character, keyed by the instruction and the classes
	// on either side. Match is one of the items.
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
	looks:        [dynamic]Leading_Look, // the look-aheads the program begins with (`leading_looks`)
	stamp:        u32,
	in_set:       []u32, // the stamp of the set that last held each thread
	walk:         u32,
	pc_seen:      []u32, // the walk number of the closure that last reached each instruction
	item_seen:    []u32, // the walk number of the closure that last took each item
	todo:         [dynamic]int,
	row_key:      [dynamic]u32,
	work:         int,
	gates:        [2]^Gate, // the allocators of the automaton and of the build
}

// The states found so far. `ids` maps each state's key, its threads followed by the class before them, to its row.
// `sets` holds the keys and `table` the transitions.
@(private = "file")
States :: struct {
	ids:    map[string]u32,
	sets:   [dynamic][]u32, // in the order of their rows, after the rows that have no key
	table:  [dynamic]u32,
	stride: u32,
}

// What the automaton reads: the class of each symbol (`classes`) and of the text's end (`final`), which reads the
// symbol of a newline (`newline_sym`) as the column past the symbols, and the symbols each atom takes.
@(private = "file")
Alphabet :: struct {
	classes:     []u8,
	final:       u8,
	syms:        int,
	newline_sym: int,
	atom_syms:   [][4]u64,
}

// The symbol and class that column `col` of a row reads: the columns 0 to `syms` - 1 are the symbols, `syms` the text's
// end.
@(private = "file")
column :: #force_inline proc(a: ^Alphabet, col: int) -> (sym, class: int) {
	if col < a.syms {
		return col, int(a.classes[col])
	}
	return a.newline_sym, int(a.final)
}

// A look-ahead the program begins with. The product runs an automaton of its body from the text's start.
@(private = "file")
Leading_Look :: struct {
	body:     i32, // the body's first instruction
	negative: bool,
}

// Whether an allocation of the build has failed, which leaves what it asked for empty.
broke :: #force_inline proc(b: ^Builder) -> bool {
	return b.gates[0].failed || b.gates[1].failed
}

// Adds `steps` to the build's work, false once it passes DFA_MAX_WORK.
charge :: #force_inline proc(b: ^Builder, steps: int) -> bool {
	b.work += steps
	return b.work <= DFA_MAX_WORK && !broke(b)
}

// Returns the automaton for `re`, allocated in `allocator`, or nil when the program has an instruction it does not run
// or a cap is passed. With `spans` it also builds `first` and `last` when the program allows. The build's working
// memory comes from `scratch` and is freed before it returns. The build gives up when an allocation of either gate has
// failed, and the caller reads that.
build_dfa :: proc(re: ^Regex, spans: bool, out, tmp: ^Gate) -> ^Dfa {
	allocator, scratch := gate_allocator(out), gate_allocator(tmp)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, scratch, scratch, block_size = 8192, out_band_size = 2048)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)

	b := Builder{re = re, gates = {out, tmp}}
	if !leading_looks(&b) || !enumerate_items(&b) {
		return nil
	}
	n := len(b.atom_of)
	b.pc_seen = make([]u32, len(re.insts))
	b.item_seen = make([]u32, n)
	b.in_set = make([]u32, n + len(re.insts))
	b.after = make([][]u32, n)
	if broke(&b) {
		return nil
	}
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
			return atom >= 0 && has_bit(atom_syms[atom][:], s)
		}
		c = NEWLINE if takes(atom_syms, newline, s) else WORD if takes(atom_syms, word, s) else OTHER
	}
	newline_sym := int(ascii['\n'])
	final := u8(FINAL) if b.lines || b.semi_end else classes[newline_sym]
	b.used[EDGE], b.used[final] = true, true
	for c in classes {
		b.used[c] = true
	}
	alphabet := Alphabet{classes, final, syms, newline_sym, atom_syms}
	stride := u32(syms + 2)
	// A search starts with one thread at the program's start and adds another after each character it reads.
	restart := u32(n)
	b.restart_dies = true
	for before := NEWLINE; ok && b.restart_dies && before < CLASSES; before += 1 {
		for after := 0; ok && b.restart_dies && after < CLASSES; after += 1 {
			reach: []u32
			reach, ok = closure_of(&b, 0, before, after)
			b.restart_dies = len(reach) == 0
		}
	}
	st: States
	starts: [CLASSES]u32
	start_end: u32
	if ok {
		st, starts, start_end, ok = build_rows(&b, restart, true, false, &alphabet)
	}
	if ok && len(b.looks) > 0 {
		st, starts, ok = build_product(&b, st, starts, &alphabet)
		start_end = 0
	}
	if !ok {
		return nil
	}
	first, last: States
	first_starts, last_starts: [CLASSES]u32
	first_end: u32
	// Oniguruma ends an empty iteration by where it began and ECMA fails it, which the threads of a position do not
	// record. The threads of a leading look-ahead's product are not ordered.
	has_first := spans && !b.empty_loops && !b.keeps && len(b.looks) == 0
	if has_first {
		first, first_starts, first_end, has_first = build_rows(&b, u32(len(b.atom_of)), true, true, &alphabet)
	}
	if has_first {
		last, last_starts, has_first = build_last(&b, &alphabet)
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
		head    = re.head^,
		anchored = b.restart_dies,
	}
	if has_first {
		d.first, d.first_starts, d.first_end = slice.clone(first.table[:]), first_starts, first_end
		d.last, d.last_starts = slice.clone(last.table[:]), last_starts
	}
	// When `head` gives no first byte there is nothing to skip to, so no row is a start row and the search does not
	// check for a skip at each byte.
	if d.head.kind == .None {
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

// Sets `bucket` to the threads the items `reached` go on to after reading the symbol `sym`, in their order.
@(private = "file")
step_bucket :: proc(b: ^Builder, bucket: ^[dynamic]u32, reached: []u32, sym: int, a: ^Alphabet) -> bool {
	charge(b, 1 + len(reached)) or_return
	b.stamp += 1
	clear(bucket)
	for it in reached {
		if !has_bit(a.atom_syms[b.atom_of[it]][:], sym) {
			continue
		}
		charge(b, len(b.after[it])) or_return
		for x in b.after[it] {
			add_item(b, bucket, x)
		}
	}
	return true
}

// Builds the whether automaton from one thread at `start`. With `restart`, a thread at the program's start is added
// after each character. The rows before `start_end` are those of `start` alone.
//
// With `$first` it builds the automaton of the first match in the backtracker's order. A state is the threads after
// the characters read so far, in the order the backtracker tries them, with the class of the last character and
// whether a match has ended. It follows every path of the backtracker's search at once. A thread that reaches Match
// ends a match there and drops every thread after it, which the backtracker would try only if that match failed. The
// thread at the program's start that each character adds comes last, and only until a match has ended. The last match
// end the search sees is the backtracker's: the first in its order to end, at the earliest start that has a match.
@(private = "file")
build_rows :: proc(
	b: ^Builder,
	start: u32,
	restart: bool,
	$first: bool,
	a: ^Alphabet,
) -> (
	st: States,
	starts: [CLASSES]u32,
	start_end: u32,
	ok: bool,
) {
	n := len(b.atom_of)
	stride := u32(a.syms + 2)
	st.stride = stride
	// Row 0 is the dead state. In the whether automaton row 1 is the matched state, which every character leads back
	// to.
	head := 1 if first else 2
	resize(&st.table, head * int(stride))
	if !first {
		for k in 0 ..< int(stride) {
			st.table[int(stride) + k] = MATCHED * stride
		}
	}
	for c in 0 ..< CLASSES {
		starts[c] = first_row(b, &st, {start}, c, false) or_return
	}
	start_end = u32(len(st.table))
	matched_row := FIRST_ENDS if first else MATCHED * stride
	bucket := make([dynamic]u32)
	for k := 0; k < len(st.sets); k += 1 {
		set := st.sets[k]
		threads, before, ended := set[:len(set) - 1], int(set[len(set) - 1] & 0xFF), set[len(set) - 1] >> 8 != 0
		at := (head + k) * int(stride)
		reached: [CLASSES][]u32
		matched: [CLASSES]bool
		for c in 0 ..< CLASSES {
			if !b.used[c] {
				continue
			}
			reached[c], matched[c] = expand(b, threads, before, c, first) or_return
		}
		for col in 0 ..= a.syms {
			sym, c := column(a, col)
			if matched[c] && !first {
				st.table[at + col] = matched_row
				continue
			}
			step_bucket(b, &bucket, reached[c], sym, a) or_return
			now_ended := ended || matched[c]
			if restart && !now_ended {
				add_item(b, &bucket, u32(n))
			}
			// With `$first` the threads keep the backtracker's order. Without it they are a set and are sorted.
			if !first {
				sort_items(bucket[:])
			}
			target := first_row(b, &st, bucket[:], c, now_ended) or_return
			st.table[at + col] = target | (FIRST_ENDS if matched[c] else 0)
		}
		st.table[at + a.syms + 1] = matched_row if matched[EDGE] else DEAD
	}
	return st, starts, start_end, true
}

// Builds the whether automaton of a program that begins with look-aheads at the text's start. `main` is the program's
// own automaton with each look-ahead skipped. A state is a row of each part: the program, and each look-ahead's body
// read from the text's start to its end. A state matches once the program and every positive body have matched and no
// negative body has a thread left. It is dead once the program or a positive body has no thread left, or a negative
// body has matched.
@(private = "file")
build_product :: proc(
	b: ^Builder,
	main: States,
	main_starts: [CLASSES]u32,
	a: ^Alphabet,
) -> (
	st: States,
	starts: [CLASSES]u32,
	ok: bool,
) {
	n := len(b.atom_of)
	parts := make([]States, 1 + len(b.looks))
	part_starts := make([][CLASSES]u32, len(parts))
	parts[0], part_starts[0] = main, main_starts
	for look, k in b.looks {
		parts[1 + k], part_starts[1 + k], _ = build_rows(b, u32(n + int(look.body)), false, false, a) or_return
	}
	stride := main.stride
	st.stride = stride
	resize(&st.table, 2 * int(stride))
	for k in 0 ..< int(stride) {
		st.table[int(stride) + k] = MATCHED * stride
	}
	rows := make([]u32, len(parts))
	for c in 0 ..< CLASSES {
		for &r, k in rows {
			r = part_starts[k][c]
		}
		starts[c] = product_row(b, &st, rows) or_return
	}
	for k := 0; k < len(st.sets); k += 1 {
		at := (2 + k) * int(stride)
		charge(b, int(stride) * len(parts)) or_return
		for col in 0 ..< stride {
			for &r, j in rows {
				r = parts[j].table[st.sets[k][j] + col]
			}
			target := product_row(b, &st, rows) or_return
			st.table[at + int(col)] = target
		}
	}
	return st, starts, true
}

// Returns the row of the state with the sorted `key`. A new state is queued for its transitions when none has the key.
// False past a cap.
@(private = "file")
intern_row :: proc(b: ^Builder, st: ^States, key: []u32) -> (row: u32, ok: bool) {
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
	// The table grows by doubling, so the copies it leaves in the arena total no more than its final size.
	if len(st.table) + stride > cap(st.table) {
		reserve(&st.table, max(2 * cap(st.table), len(st.table) + stride))
	}
	resize(&st.table, len(st.table) + stride)
	return row, true
}

// Returns the row of the state whose parts are in `rows`. A new state is queued when none has them. False past a cap.
@(private = "file")
product_row :: proc(b: ^Builder, st: ^States, rows: []u32) -> (row: u32, ok: bool) {
	matched := MATCHED * st.stride
	done := rows[0] == matched
	if rows[0] == DEAD {
		return DEAD, true
	}
	for look, k in b.looks {
		r := rows[1 + k]
		if r == (matched if look.negative else DEAD) {
			return DEAD, true
		}
		done &&= r == (DEAD if look.negative else matched)
	}
	if done {
		return matched, true
	}
	return intern_row(b, st, rows)
}

// Returns the row of the state of `threads`, in their order, after a character of class `read`. `ended` is whether a
// match has ended, always false for the whether automaton. A new state is queued when none has the key. False past a
// cap. A thread whose closure reaches nothing whatever comes next is left out, and so is the thread at the program's
// start when it reaches nothing past the text's start. A state with no thread left is the dead row.
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
	return intern_row(b, st, key)
}

// Builds the automaton read backwards from a match's end. A state is the items that, at the place it has read back to,
// read on to the end and reach Match there, with the class of the character after that place. An item is in the state
// after a character when it reads that character and one item its next threads reach is in the previous state. A match
// starts at a place when the program's start reaches one of the state's items there.
@(private = "file")
build_last :: proc(b: ^Builder, a: ^Alphabet) -> (st: States, starts: [CLASSES]u32, ok: bool) {
	n := len(b.atom_of)
	stride := u32(a.syms + 2)
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
		for col in 0 ..= a.syms {
			sym, c := column(a, col)
			charge(b, 1 + len(reading[c])) or_return
			clear(&bucket)
			for it in reading[c] {
				if has_bit(a.atom_syms[b.atom_of[it]][:], sym) {
					append(&bucket, it)
				}
			}
			target := last_row(b, &st, bucket[:], c) or_return
			st.table[at + col] = target | (FIRST_ENDS if starts_here[c] else 0)
		}
		st.table[at + a.syms + 1] = FIRST_ENDS if starts_here[EDGE] else DEAD
	}
	return st, starts, true
}

// Returns the row of the state of sorted `items` before a character of class `after`. A new state is queued when none
// has it. False past a cap. A state with no item is the dead row.
@(private = "file")
last_row :: proc(b: ^Builder, st: ^States, items: []u32, after: int) -> (row: u32, ok: bool) {
	if len(items) == 0 {
		return DEAD, true
	}
	clear(&b.row_key)
	append(&b.row_key, ..items)
	append(&b.row_key, u32(after))
	key := b.row_key[:]
	return intern_row(b, st, key)
}

// Returns class `c` of the character before a place, reduced to the classes the program's assertions read. A class
// none of them reads becomes OTHER, and EDGE stays.
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

// Collects the look-aheads an ECMA program begins with after `^` into `b.looks`. False for a program with a look-around
// anywhere else. Anchored at the text's start, each look-ahead tests a prefix of the text, which a product of automata
// runs. The program's own automaton skips them.
@(private = "file")
leading_looks :: proc(b: ^Builder) -> bool {
	insts := b.re.insts
	anchored := false
	pc := 0
	lead: for ; pc < len(insts); pc += 1 {
		ins := insts[pc]
		#partial switch ins.op {
		case .Save, .Set, .Unset:
		case .Assert:
			if Assert_Kind(ins.a) != .Begin_Buf {
				break lead
			}
			anchored = true
		case .Look:
			kind := Look_Kind(ins.a)
			if !b.re.ecma || !anchored || kind != .Ahead && kind != .Not_Ahead || len(b.looks) == DFA_MAX_LOOKS {
				return false
			}
			for body in pc + 1 ..< int(ins.b) {
				if insts[body].op == .Look {
					return false
				}
			}
			append(&b.looks, Leading_Look{i32(pc + 1), kind == .Not_Ahead})
			pc = int(ins.b)
		case:
			break lead
		}
	}
	for ; pc < len(insts); pc += 1 {
		if insts[pc].op == .Look {
			return false
		}
	}
	return true
}

// Creates an item for each place where the program reads a character: one per character of a Str, one per
// one-character test, one per count a Rep can read at, and one for Match or Look_End. For an unbounded Rep every count
// past the minimum is treated as the minimum. False for a program the automaton does not run.
@(private = "file")
enumerate_items :: proc(b: ^Builder) -> bool {
	re := b.re
	insts := re.insts
	b.base = make([]i32, len(insts))
	slice.fill(b.base, -1)
	if broke(b) {
		return false
	}
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
		case .Look_End:
			add_items(b, pc, 1, MATCH_ITEM)
		case .Split, .Split_Head, .Jmp, .Set, .Unset, .Look:
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

// Returns the items, Match among them, that a thread at instruction `pc` reaches through instructions that read
// nothing, between a character of class `before` and one of class `after`. Each visited instruction is charged. The
// result is cached in `b.closures`.
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
	// The instructions are visited in the order of their alternatives, so the items come out in that order. An entry
	// past the program is a lazy Rep's first item, taken after its exit.
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
		case .Look:
			// Only a leading look-ahead reaches here. Its body is a part of the product, so the thread skips it.
			append(&b.todo, int(ins.b) + 1)
		case .Look_End:
			take(b, &set, b.base[at])
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

// Returns the reading items `threads` reach, in order, between a character of class `before` and one of class `after`,
// and whether Match is among what they reach. With `$stop` the reach ends at the first Match, since the threads after
// it are ones the backtracker would try only if that match failed.
@(private = "file")
expand :: proc(
	b: ^Builder,
	threads: []u32,
	before, after: int,
	$stop: bool,
) -> (
	items: []u32,
	matched: bool,
	ok: bool,
) {
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
				when stop {
					break walk
				}
			} else {
				add_item(b, &set, it)
			}
		}
	}
	return set[:], matched, true
}

// Returns the threads after reading item `it`'s character, in the order of their alternatives: the next item of the
// same instruction, or a thread at the instruction that follows.
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

// Sorts the items of a thread set. Most hold a few items, which an insertion sort orders faster than the general sort
// starts.
@(private = "file")
sort_items :: proc(items: []u32) {
	if len(items) > 32 {
		slice.sort(items)
		return
	}
	for i in 1 ..< len(items) {
		x, j := items[i], i
		for j > 0 && items[j - 1] > x {
			items[j] = items[j - 1]
			j -= 1
		}
		items[j] = x
	}
}
