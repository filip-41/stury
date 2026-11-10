#+private
package regex

// A deterministic automaton that answers whether an ECMA program matches anywhere in a text, built whole at compile
// time from the program when it holds no look-ahead and no assertion but `^` and `$`. A JSON Schema asks only that
// question of a pattern. Each step reads one character and takes one row of the table, so the answer costs one pass
// over the text whatever the pattern, and the automaton is read only, so threads share it.
//
// The automaton runs the program's language and not its order of alternatives, which is the same answer: a match
// exists exactly when some path through the program reaches Match, and ECMA's rule that an optional iteration may not
// match empty removes no path that a path without that iteration does not stand in for at the same position.
//
// Every step of the build is charged to one budget, and the build gives up past it, so its time and its working
// memory are bounded by the budget and the program's length whatever the pattern. The working memory is freed before
// the build returns, and only the automaton is kept.

import "core:mem"
import "core:slice"
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

Dfa :: struct {
	// Each state's row of `stride` entries: the start of the next state's row for each symbol, then for the text's end,
	// where a state that matches there goes to the matched row.
	table:   []u32,
	stride:  u32,
	at_text_start, at_later_start: u32, // the rows a search starts in at byte 0 and past it
	empty:   bool, // an empty text matches
	ascii:   [128]u8, // each ASCII character's symbol
	bounds:  []rune, // the first of each run of non-ASCII characters that share a symbol, from 0x80
	symbols: []u8, // the symbol of each run
}

// Whether `d`'s program matches in `s` at or after byte `start`, or judged false when the text holds a byte that does
// not begin a valid UTF-8 character there, where the backtracker's steps decide.
dfa_search :: proc(d: ^Dfa, s: string, start: int) -> (found: bool, judged: bool) {
	if start > len(s) {
		return false, true
	}
	if start == len(s) {
		if start == 0 {
			return d.empty, true
		}
		return d.table[d.at_later_start + d.stride - 1] == MATCHED * d.stride, true
	}
	st := d.at_text_start if start == 0 else d.at_later_start
	if st <= MATCHED * d.stride {
		return st == MATCHED * d.stride, true
	}
	table := d.table
	for i := start; i < len(s); {
		b := s[i]
		sym: u8
		if b < 0x80 {
			sym = d.ascii[b]
			i += 1
		} else {
			r, w := utf8.decode_rune_in_string(s[i:])
			if w == 1 {
				return false, false
			}
			sym = rune_symbol(d, r)
			i += w
		}
		st = table[st + u32(sym)]
		if st <= MATCHED * d.stride {
			return st == MATCHED * d.stride, true
		}
	}
	return table[st + d.stride - 1] == MATCHED * d.stride, true
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

// An item of a state: a place in the program that reads a character, a `$` (`atom` END_ITEM) or Match (MATCH_ITEM).
@(private = "file")
END_ITEM :: -1
@(private = "file")
MATCH_ITEM :: -2

@(private = "file")
Builder :: struct {
	re:       ^Regex,
	base:     []i32, // each instruction's first item, -1 for none
	atoms:    [dynamic]Atom,
	atom_ids: map[string]i32, // each atom by the test it was made from
	key:      [dynamic]u8,
	item_pc:  [dynamic]i32,
	item_k:   [dynamic]i32, // a Rep's count or the character within a Str
	atom_of:  [dynamic]i32, // each item's atom, END_ITEM or MATCH_ITEM
	next:     [][]u32, // each reading item's items after it reads, the restarts left out
	ends:     []bool, // each `$` item reaches Match at the text's end past its start
	stamp:    u32,
	pc_seen:  []u32, // the closure that last reached each instruction
	in_set:   []u32, // the set that last took each item
	todo:     [dynamic]int,
	reached:  [dynamic]u32,
	work:     int,
}

// Charges `steps` to the build's budget, false once it is spent.
@(private = "file")
charge :: #force_inline proc(b: ^Builder, steps: int) -> bool {
	b.work += steps
	return b.work <= DFA_MAX_WORK
}

// The states found so far: each one's items and row, and the table of their transitions.
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
	b.in_set = make([]u32, n)
	b.next = make([][]u32, n)
	b.ends = make([]bool, n)
	ok := true
	for i := 0; ok && i < n; i += 1 {
		switch b.atom_of[i] {
		case MATCH_ITEM:
		case END_ITEM:
			b.ends[i], ok = end_matches(&b, i, false)
		case:
			b.next[i], ok = after_read(&b, i)
		}
	}
	restart, from_start: []u32
	if ok {
		restart, ok = closure(&b, 0, false)
	}
	if ok {
		from_start, ok = closure(&b, 0, true)
	}
	empty := false
	for it in from_start {
		if ok && !empty && b.atom_of[it] == END_ITEM {
			empty, ok = end_matches(&b, int(it), true)
		}
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
	stride := u32(syms + 1)

	st := States{stride = stride}
	resize(&st.table, 2 * int(stride))
	for k in 0 ..< int(stride) {
		st.table[int(stride) + k] = MATCHED * stride
	}
	at_text_start, at_later_start: u32
	if at_text_start, ok = row(&b, &st, from_start); ok {
		at_later_start, ok = row(&b, &st, restart)
	}
	bucket := make([dynamic]u32)
	for k := 0; ok && k < len(st.sets); k += 1 {
		set := st.sets[k]
		at := (2 + k) * int(stride)
		for sym := 0; ok && sym < syms; sym += 1 {
			if ok = charge(&b, 1 + len(set) + len(restart)); !ok {
				break
			}
			b.stamp += 1
			clear(&bucket)
			for it in set {
				atom := b.atom_of[it]
				if atom < 0 || atom_syms[atom][sym >> 6] & (1 << (u64(sym) & 63)) == 0 {
					continue
				}
				if ok = charge(&b, len(b.next[it])); !ok {
					break
				}
				for x in b.next[it] {
					add_item(&b, &bucket, x)
				}
			}
			if !ok {
				break
			}
			for x in restart {
				add_item(&b, &bucket, x)
			}
			sort_keys(bucket[:])
			target: u32
			if target, ok = row(&b, &st, bucket[:]); ok {
				st.table[at + sym] = target
			}
		}
		st.table[at + syms] = DEAD
		for it in set {
			if b.atom_of[it] == END_ITEM && b.ends[it] {
				st.table[at + syms] = MATCHED * stride
			}
		}
	}
	if !ok {
		return nil
	}

	context.allocator = allocator
	d := new(Dfa)
	d^ = {
		table          = slice.clone(st.table[:]),
		stride         = stride,
		at_text_start  = at_text_start,
		at_later_start = at_later_start,
		empty          = empty || at_text_start == MATCHED * stride,
		ascii          = ascii,
		bounds         = slice.clone(bounds),
		symbols        = slice.clone(symbols),
	}
	return d
}

// The row of the state whose items are `set`, a new state queued for its transitions when none has them, or false past
// a cap. `set` is copied only for a new state.
@(private = "file")
row :: proc(b: ^Builder, st: ^States, set: []u32) -> (u32, bool) {
	if len(set) == 0 {
		return DEAD, true
	}
	for it in set {
		if b.atom_of[it] == MATCH_ITEM {
			return MATCHED * st.stride, true
		}
	}
	if at, seen := st.ids[string(slice.to_bytes(set))]; seen {
		return at, true
	}
	stride := int(st.stride)
	if len(st.sets) >= DFA_MAX_STATES || len(st.table) + stride > DFA_MAX_TABLE || !charge(b, len(set) + stride) {
		return 0, false
	}
	owned := slice.clone(set)
	at := u32(len(st.table))
	st.ids[string(slice.to_bytes(owned))] = at
	append(&st.sets, owned)
	// The table grows by doubling, so the copies it leaves in the arena add up to no more than its final size.
	if len(st.table) + stride > cap(st.table) {
		reserve(&st.table, max(2 * cap(st.table), len(st.table) + stride))
	}
	resize(&st.table, len(st.table) + stride)
	return at, true
}

// Gives each place the program reads a character at an item: a Str one per character, a class one, a Rep one per count
// it can read at (a count past the least, of an unbounded Rep, counted as the least). False for a program the automaton
// does not run.
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
			#partial switch Assert_Kind(ins.a) {
			case .Begin_Buf:
				continue
			case .End_Buf:
				add_items(b, pc, 1, END_ITEM)
			case:
				return false
			}
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
		case .Class:
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
		case .Split, .Split_Head, .Jmp, .Save, .Set, .Unset, .Check:
			continue
		case:
			return false
		}
		b.base[pc] = first
		if len(b.atom_of) > DFA_MAX_ITEMS {
			return false
		}
	}
	return true
}

@(private = "file")
add_items :: proc(b: ^Builder, pc, count: int, atom: i32, k := 0) {
	for j in 0 ..< count {
		append(&b.item_pc, i32(pc))
		append(&b.item_k, i32(k + j))
		append(&b.atom_of, atom)
	}
}

// The atom of a class or of a Str of one character, false for a test the automaton does not run.
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

// The atom of class `cls`, one for every class that names the same ranges and properties, false for a class that folds
// or reads a derived table.
@(private = "file")
class_atom :: proc(b: ^Builder, cls: ^Class) -> (i32, bool) {
	if cls.fold || word_type(cls) {
		return 0, false
	}
	clear(&b.key)
	count := transmute([4]u8)u32(len(cls.ranges))
	append(&b.key, 'c', u8(cls.negated))
	append(&b.key, ..count[:])
	for g in cls.ranges {
		x := transmute([8]u8)g
		append(&b.key, ..x[:])
	}
	for it in cls.props {
		if int(it.table) >= TABLE_CLASS_WORD {
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
	runs := make([dynamic][2]rune)
	for g in cls.ranges {
		if g[1] >= 0x80 {
			append(&runs, [2]rune{max(g[0], 0x80), g[1]})
		}
	}
	for it in cls.props {
		t := int(it.table)
		entries := PROPERTY_RANGES[PROPERTY_TABLES[t]:PROPERTY_TABLES[t + 1]]
		if !charge(b, len(entries)) {
			return 0, false
		}
		from := len(runs)
		for e in entries {
			lo := rune(e >> RANGE_SPAN_BITS)
			hi := lo + rune(e & (1 << RANGE_SPAN_BITS - 1))
			if hi >= 0x80 {
				append(&runs, [2]rune{max(lo, 0x80), hi})
			}
		}
		if it.neg {
			flipped := complement_runs(merge_runs(runs[from:]))
			resize(&runs, from)
			append(&runs, ..flipped)
		}
	}
	if !charge(b, len(runs)) {
		return 0, false
	}
	merged := merge_runs(runs[:])
	return add_atom(b, {ascii = cls.ascii, runs = complement_runs(merged) if cls.negated else merged})
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

// The non-ASCII characters sorted runs `runs` leave out, as runs.
@(private = "file")
complement_runs :: proc(runs: [][2]rune) -> [][2]rune {
	out := make([dynamic][2]rune, 0, len(runs) + 1)
	lo := rune(0x80)
	for g in runs {
		if g[0] > lo {
			append(&out, [2]rune{lo, g[0] - 1})
		}
		lo = g[1] + 1
	}
	if lo <= utf8.MAX_RUNE {
		append(&out, [2]rune{lo, utf8.MAX_RUNE})
	}
	return out[:]
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

// The items a closure from instruction `pc` reaches, with `^` holding when `begin`, in a new stamp's set.
@(private = "file")
closure :: proc(b: ^Builder, pc: int, begin: bool) -> ([]u32, bool) {
	b.stamp += 1
	set := make([dynamic]u32)
	if !follow(b, &set, pc, begin) {
		return nil, false
	}
	sort_keys(set[:])
	return set[:], true
}

// Adds to `set` the items reached from `pc` by the instructions that read nothing, under the set's stamp, charging each
// instruction it visits. At the text's `end` no item reads, and `$` holds.
@(private = "file")
follow :: proc(b: ^Builder, set: ^[dynamic]u32, pc: int, begin: bool, end := false) -> bool {
	insts := b.re.insts
	clear(&b.todo)
	append(&b.todo, pc)
	for len(b.todo) > 0 {
		at := pop(&b.todo)
		if b.pc_seen[at] == b.stamp {
			continue
		}
		b.pc_seen[at] = b.stamp
		if !charge(b, 1) {
			return false
		}
		ins := insts[at]
		#partial switch ins.op {
		case .Match:
			add_item(b, set, u32(b.base[at]))
		case .Str, .Class:
			if !end {
				add_item(b, set, u32(b.base[at]))
			}
		case .Assert:
			if Assert_Kind(ins.a) == .End_Buf && !end {
				add_item(b, set, u32(b.base[at]))
			} else if Assert_Kind(ins.a) == .End_Buf || begin {
				append(&b.todo, at + 1)
			}
		case .Split:
			append(&b.todo, int(ins.b), int(ins.a))
		case .Split_Head:
			append(&b.todo, int(ins.b), at + 1)
		case .Jmp:
			append(&b.todo, int(ins.a))
		case .Save, .Set, .Unset, .Check:
			// An empty iteration ECMA's Check fails is a path the loop's exit already takes.
			append(&b.todo, at + 1)
		case .Rep, .Rep_Lazy:
			if ins.b != 0 && !end {
				add_item(b, set, u32(b.base[at]))
			}
			if ins.a == 0 {
				append(&b.todo, at + 2)
			}
		}
	}
	return true
}

// The items after reading item `it`'s character, past the start of the text.
@(private = "file")
after_read :: proc(b: ^Builder, it: int) -> ([]u32, bool) {
	pc, k := int(b.item_pc[it]), int(b.item_k[it])
	ins := b.re.insts[pc]
	b.stamp += 1
	set := make([dynamic]u32)
	ok := true
	#partial switch ins.op {
	case .Str:
		if it + 1 < len(b.item_pc) && int(b.item_pc[it + 1]) == pc {
			add_item(b, &set, u32(it + 1))
		} else {
			ok = follow(b, &set, pc + 1, false)
		}
	case .Rep, .Rep_Lazy:
		count := k + 1
		if ins.b < 0 {
			count = min(count, int(ins.a))
		}
		if ins.b < 0 || count < int(ins.b) {
			add_item(b, &set, u32(int(b.base[pc]) + count))
		}
		if count >= int(ins.a) {
			ok = follow(b, &set, pc + 2, false)
		}
	case:
		ok = follow(b, &set, pc + 1, false)
	}
	sort_keys(set[:])
	return set[:], ok
}

// Whether `$` item `it` reaches Match at the text's end, with `^` holding when `begin`.
@(private = "file")
end_matches :: proc(b: ^Builder, it: int, begin: bool) -> (matched: bool, ok: bool) {
	b.stamp += 1
	clear(&b.reached)
	if !follow(b, &b.reached, int(b.item_pc[it]) + 1, begin, true) {
		return false, false
	}
	for x in b.reached {
		if b.atom_of[x] == MATCH_ITEM {
			return true, true
		}
	}
	return false, true
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
