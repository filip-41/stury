#+private
package regex

// The subset construction of the automaton in dfa.odin.
//
// A state is the program's threads after the characters read so far, with the class of the last character. A thread is
// a reading item, or an instruction whose closure is still to be followed. An assertion reads the class of the
// character after its place, so closures are followed as the next symbol is read, whose class the table knows.
//
// Every step of the build is charged to a single budget (`Builder.work`) and the build gives up past DFA_MAX_WORK. So
// its time and working memory are bounded by the budget whatever the pattern. The working memory is freed before the
// build returns and only the automaton is kept.

import "core:mem"
import "core:slice"

@(private = "file")
DFA_MAX_STATES :: 1024
@(private = "file")
DFA_MAX_TABLE :: 1 << 18 // entries of the table, its rows times their stride

// The states found so far. `ids` maps each state's key, its threads followed by the class before them, to its row.
// `sets` holds the keys and `table` the transitions.
@(private = "file")
States :: struct {
	ids:    map[string]u32,
	sets:   [dynamic][]u32, // in the order of their rows, after the rows that have no key
	table:  [dynamic]u32,
	stride: u32,
}

// Returns the automaton for `re`, allocated through `out`, or nil when the program has an instruction it does not run
// or a cap is passed. With `spans` it also builds `first` and `last` when the program allows. The build's working
// memory comes from `tmp` and is freed before it returns. The build gives up when an allocation of either gate has
// failed, and the caller reads that.
build_dfa :: proc(re: ^Regex, spans: bool, out, tmp: ^Gate) -> ^Dfa {
	allocator, scratch := gate_allocator(out), gate_allocator(tmp)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, scratch, scratch, block_size = 8192, out_band_size = 2048)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)

	b := Builder{atoms_ctx = {re = re, gates = {out, tmp}}}
	if !leading_looks(&b) || !enumerate_items(&b) {
		return nil
	}
	n := len(b.items)
	b.pc_seen = make([]u32, len(re.insts))
	b.item_seen = make([]u32, n)
	b.in_set = make([]u32, n + len(re.insts))
	b.after = make([][]u32, n)
	if !charge(&b, 0) {
		return nil
	}
	for i in 0 ..< n {
		if b.items[i].atom != MATCH_ITEM {
			b.after[i] = after_read(&b, i)
		}
	}
	ok := charge(&b, n)
	alphabet: Alphabet
	if ok {
		alphabet, ok = build_alphabet(&b, b.lines, b.word, b.ascii_word, b.semi_end)
	}
	if !ok {
		return nil
	}
	b.used[EDGE], b.used[alphabet.final] = true, true
	for c in alphabet.classes {
		b.used[c] = true
	}
	stride := u32(alphabet.syms + 2)
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
		first, first_starts, first_end, has_first = build_rows(&b, u32(len(b.items)), true, true, &alphabet)
	}
	if has_first {
		last, last_starts, has_first = build_last(&b, &alphabet)
	}

	context.allocator = allocator
	d := new(Dfa)
	d^ = {
		table     = slice.clone(st.table[:]),
		stride    = stride,
		starts    = starts,
		ascii     = alphabet.ascii,
		bounds    = slice.clone(alphabet.bounds),
		symbols   = slice.clone(alphabet.symbols),
		classes   = slice.clone(alphabet.classes),
		final     = alphabet.final,
		start_end = start_end,
		head      = re.head,
		anchored  = b.restart_dies,
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
	if !re.ecma && !re.linear {
		reps := make([dynamic]i32, mem.dynamic_arena_allocator(&arena))
		loops: for ins, pc in re.insts {
			#partial switch ins.op {
			case .Split:
				if int(ins.a) <= pc || int(ins.b) <= pc {
					d.splits = -1
					break loops
				}
				d.splits += 1
			case .Split_Head:
				d.splits = -1
				break loops
			case .Jmp:
				if int(ins.a) <= pc {
					d.splits = -1
					break loops
				}
			case .Rep, .Rep_Lazy:
				if ins.a != ins.b {
					append(&reps, -1 if ins.b < 0 else ins.b - ins.a + 1)
				}
			}
		}
		if d.splits >= 0 && len(reps) > 0 {
			d.reps = slice.clone(reps[:])
		}
	}
	return d
}

// Initializes a state table with row 0 as DEAD and, with `with_matched`, row 1 as MATCHED.
@(private = "file")
init_states :: proc(b: ^Builder, stride: u32, with_matched: bool) -> (st: States, ok: bool) {
	st.stride = stride
	head := 2 if with_matched else 1
	resize(&st.table, head * int(stride))
	charge(b, 0) or_return
	if with_matched {
		slice.fill(st.table[stride:2 * stride], MATCHED * stride)
	}
	return st, true
}

// Sets `bucket` to the threads the items `reached` go on to after reading the symbol `sym`, in their order.
@(private = "file")
step_bucket :: proc(b: ^Builder, bucket: ^[dynamic]u32, reached: []u32, sym: int, a: ^Alphabet) -> bool {
	charge(b, 1 + len(reached)) or_return
	b.stamp += 1
	clear(bucket)
	for it in reached {
		if !has_bit(a.atom_syms[b.items[it].atom][:], sym) {
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
	n := len(b.items)
	stride := u32(a.syms + 2)
	head := 1 if first else 2
	st = init_states(b, stride, !first) or_return
	for c in 0 ..< CLASSES {
		starts[c] = first_row(b, &st, {start}, c, false) or_return
	}
	start_end = u32(len(st.table))
	matched_row := FIRST_ENDS if first else MATCHED * stride
	bucket := make([dynamic]u32)
	reached: [CLASSES][dynamic]u32
	for k := 0; k < len(st.sets); k += 1 {
		set := st.sets[k]
		threads, before, ended := set[:len(set) - 1], int(set[len(set) - 1] & 0xFF), set[len(set) - 1] >> 8 != 0
		at := (head + k) * int(stride)
		matched: [CLASSES]bool
		for c in 0 ..< CLASSES {
			if !b.used[c] {
				continue
			}
			matched[c] = expand(b, &reached[c], threads, before, c, first) or_return
		}
		for col in 0 ..= a.syms {
			sym, c := column(a, col)
			if matched[c] && !first {
				st.table[at + col] = matched_row
				continue
			}
			step_bucket(b, &bucket, reached[c][:], sym, a) or_return
			now_ended := ended || matched[c]
			if restart && !b.restart_dies && !now_ended {
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
	n := len(b.items)
	parts := make([]States, 1 + len(b.looks))
	part_starts := make([][CLASSES]u32, len(parts))
	rows := make([]u32, len(parts))
	charge(b, 0) or_return
	parts[0], part_starts[0] = main, main_starts
	for look, k in b.looks {
		parts[1 + k], part_starts[1 + k], _ = build_rows(b, u32(n + int(look.body)), false, false, a) or_return
	}
	stride := main.stride
	st = init_states(b, stride, true) or_return
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

// Returns the row of the state with `key`. A new state is queued for its transitions when none has the key. False past
// a cap.
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
	return row, charge(b, 0)
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
	n := len(b.items)
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
	return intern_row(b, st, b.row_key[:])
}

// Builds the automaton read backwards from a match's end. A state is the items that, at the place it has read back to,
// read on to the end and reach Match there, with the class of the character after that place. An item is in the state
// after a character when it reads that character and one item its next threads reach is in the previous state. A match
// starts at a place when the program's start reaches one of the state's items there.
@(private = "file")
build_last :: proc(b: ^Builder, a: ^Alphabet) -> (st: States, starts: [CLASSES]u32, ok: bool) {
	n := len(b.items)
	stride := u32(a.syms + 2)
	st = init_states(b, stride, false) or_return
	ends := make([dynamic]u32)
	for it in 0 ..< n {
		if b.items[it].atom == MATCH_ITEM {
			append(&ends, u32(it))
		}
	}
	for c in 0 ..< CLASSES {
		starts[c] = last_row(b, &st, ends[:], c) or_return
	}
	bucket := make([dynamic]u32)
	reading: [CLASSES][dynamic]u32
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
		starts_here: [CLASSES]bool
		for c in 0 ..< CLASSES {
			if !b.used[c] {
				continue
			}
			found := &reading[c]
			clear(found)
			for it in 0 ..< n {
				if b.items[it].atom == MATCH_ITEM {
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
					append(found, u32(it))
				}
			}
			reach := closure_of(b, 0, c, after) or_return
			for y in reach {
				if b.in_set[y] == mark {
					starts_here[c] = true
					break
				}
			}
		}
		for col in 0 ..= a.syms {
			sym, c := column(a, col)
			charge(b, 1 + len(reading[c])) or_return
			clear(&bucket)
			for it in reading[c] {
				if has_bit(a.atom_syms[b.items[it].atom][:], sym) {
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
	return intern_row(b, st, b.row_key[:])
}

// Sorts the items of a thread set. Most hold a few items, which an insertion sort orders faster than `_smoothsort`.
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
