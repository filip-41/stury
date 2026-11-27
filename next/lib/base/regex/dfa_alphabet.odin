#+private
package regex

// Atoms, the character sets that the program's tests accept, and the symbols that divide the characters by which atoms
// accept them.

import "core:slice"
import "core:unicode/utf8"

// Limits shared with the automaton builder. A program past any of them gets no automaton and the visited set answers.
DFA_MAX_ITEMS :: 2048
@(private = "file")
DFA_MAX_SYMBOLS :: 255
@(private = "file")
DFA_MAX_WORK :: 1 << 18 // instructions visited, set entries moved, ranges and cuts swept

// The characters a character test of the program accepts: ASCII characters as bits, non-ASCII ones as sorted runs that
// neither overlap nor touch.
@(private = "file")
Atom :: struct {
	ascii: [2]u64,
	runs:  [][2]rune,
}

// Atom interning state and shared build budget for `dfa_alphabet.odin`, embedded in `Builder`.
Atoms :: struct {
	re:       ^Regex,
	atoms:    [dynamic]Atom,
	atom_ids: map[string]i32, // each atom by the test it was made from
	key:      [dynamic]u8,
	work:     int,
	gates:    [2]^Gate, // the allocators of the automaton and of the build
}

// What the automaton reads: the class of each symbol (`classes`) and of the text's end (`final`), which reads the
// symbol of a newline (`newline_sym`) as the column past the symbols, and the symbols each atom takes.
Alphabet :: struct {
	classes:     []u8,
	final:       u8,
	syms:        int,
	newline_sym: int,
	atom_syms:   [][4]u64,
	ascii:       [128]u8,
	bounds:      []rune,
	symbols:     []u8,
}

// The symbol and class that column `col` of a row reads: the columns 0 to `syms` - 1 are the symbols, `syms` the text's
// end.
column :: #force_inline proc(a: ^Alphabet, col: int) -> (sym, class: int) {
	if col < a.syms {
		return col, int(a.classes[col])
	}
	return a.newline_sym, int(a.final)
}

// Adds `steps` to the build's work, false once it passes DFA_MAX_WORK or an allocation of either gate has failed.
charge :: #force_inline proc(b: ^Atoms, steps: int) -> bool {
	b.work += steps
	return b.work <= DFA_MAX_WORK && !b.gates[0].failed && !b.gates[1].failed
}

// Returns the atom of a one-character test, false for a test the automaton does not run.
inst_atom :: proc(b: ^Atoms, ins: Inst) -> (i32, bool) {
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

rune_atom :: proc(b: ^Atoms, r: rune) -> (i32, bool) {
	clear(&b.key)
	x := transmute([4]u8)r
	append(&b.key, 'r')
	append(&b.key, ..x[:])
	if at, seen := b.atom_ids[string(b.key[:])]; seen {
		return at, true
	}
	a: Atom
	if r < 0x80 {
		add_bit(a.ascii[:], int(r))
	} else {
		a.runs = slice.clone([][2]rune{{r, r}})
	}
	return add_atom(b, a)
}

// Returns the atom of the characters whose case fold is `f`.
@(private = "file")
fold_atom :: proc(b: ^Atoms, f: rune) -> (id: i32, ok: bool) {
	clear(&b.key)
	x := transmute([4]u8)f
	append(&b.key, 'f')
	append(&b.key, ..x[:])
	if at, seen := b.atom_ids[string(b.key[:])]; seen {
		return at, true
	}
	a: Atom
	runs := make([dynamic][2]rune)
	for r := f; true; {
		if r < 0x80 {
			add_bit(a.ascii[:], int(r))
		} else {
			append(&runs, [2]rune{r, r})
		}
		if r = fold_next(r); r == f {
			break
		}
		charge(b, 1) or_return
	}
	a.runs = merge_runs(runs[:])
	return add_atom(b, a)
}

// Returns the atom of the word characters `\b` reads: ASCII ones only if `ascii_only`, else Unicode ones.
@(private = "file")
word_atom :: proc(b: ^Atoms, ascii_only: bool) -> (id: i32, ok: bool) {
	a: Atom
	for r in rune(0) ..< 0x80 {
		if is_word(r) {
			add_bit(a.ascii[:], int(r))
		}
	}
	if !ascii_only {
		runs := make([dynamic][2]rune)
		table_runs(b, &runs, TABLE_WORD, 0x80) or_return
		a.runs = merge_runs(runs[:])
	}
	append(&b.atoms, a)
	return i32(len(b.atoms) - 1), true
}

// Appends the runs of property table `t` at or above `floor`, charging the budget for its entries.
@(private = "file")
table_runs :: proc(b: ^Atoms, runs: ^[dynamic][2]rune, t: int, floor: rune) -> bool {
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

// Returns the atom of class `cls`. Classes with the same ranges, properties and folding share an atom. False for a
// class that reads a table the automaton does not.
@(private = "file")
class_atom :: proc(b: ^Atoms, cls: ^Class) -> (id: i32, ok: bool) {
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
	// A folding class accepts a character when one that folds alike with it is in the class, so ASCII ranges are
	// collected too.
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
		if t == TABLE_CLASS_WORD || it.neg {
			// In a class `\w` lacks the digits ²³¹ and the fractions ¼½¾.
			sub := complement_runs(runs[from:], floor)
			if t == TABLE_CLASS_WORD {
				append(&sub, [2]rune{0xB2, 0xB3}, [2]rune{0xB9, 0xB9}, [2]rune{0xBC, 0xBE})
				if !it.neg {
					sub = complement_runs(merge_runs(sub[:]), floor)
				}
			}
			charge(b, len(sub)) or_return
			resize(&runs, from)
			append(&runs, ..sub[:])
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

// Returns `runs`, sorted and merged, plus every character that folds alike with one in them.
@(private = "file")
fold_runs :: proc(b: ^Atoms, runs: [][2]rune) -> ([][2]rune, bool) {
	out := make([dynamic][2]rune)
	append(&out, ..runs)
	for g in runs {
		lo, _ := slice.binary_search_by(FOLDS, u64(g[0]), fold_order)
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

// Stores atom `a` and maps the key being built to its id.
@(private = "file")
add_atom :: proc(b: ^Atoms, a: Atom) -> (i32, bool) {
	at := i32(len(b.atoms))
	append(&b.atoms, a)
	b.atom_ids[string(slice.clone(b.key[:]))] = at
	return at, true
}

// Builds the automaton's alphabet from the collected atoms plus the assertion classes (newline, word). False past the
// symbol cap or the budget.
build_alphabet :: proc(b: ^Atoms, lines, word_flag, ascii_word, semi_end: bool) -> (a: Alphabet, ok: bool) {
	// The atoms of the classes the assertions read, which split the alphabet as an item's atom does.
	newline, word := i32(-1), i32(-1)
	if lines {
		newline = rune_atom(b, '\n') or_return
	}
	if word_flag || ascii_word {
		word = word_atom(b, ascii_word) or_return
	}
	ascii, bounds, symbols, atom_syms, syms := alphabet(b) or_return
	classes := make([]u8, syms)
	charge(b, 0) or_return
	for &c, s in classes {
		takes :: proc(atom_syms: [][4]u64, atom: i32, s: int) -> bool {
			return atom >= 0 && has_bit(atom_syms[atom][:], s)
		}
		c = NEWLINE if takes(atom_syms, newline, s) else WORD if takes(atom_syms, word, s) else OTHER
	}
	newline_sym := int(ascii['\n'])
	final := u8(FINAL) if lines || semi_end else classes[newline_sym]
	return Alphabet{classes, final, syms, newline_sym, atom_syms, ascii, bounds, symbols}, true
}

// Gives the characters that every atom accepts or rejects alike one symbol. Returns `ascii`, the ASCII characters'
// symbols, `bounds`, the first character of each run of non-ASCII characters with one symbol, `symbols`, the symbol of
// each run, `atom_syms`, for each atom the bit set of the symbols it accepts, and `syms`, the symbol count. False past
// the symbol cap or the budget.
@(private = "file")
alphabet :: proc(b: ^Atoms) -> (ascii: [128]u8, bounds: []rune, symbols: []u8, atom_syms: [][4]u64, syms: int, ok: bool) {
	n := len(b.atoms)
	ids := make(map[string]u8)
	atom_syms = make([][4]u64, n)
	// Bit set of the atoms that accept the characters being given a symbol.
	accepting := make([]u64, max((n + 63) / 64, 1))
	symbol :: proc(b: ^Atoms, ids: ^map[string]u8, atom_syms: [][4]u64, accepting: []u64) -> (u8, bool) {
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
			if has_bit(accepting, a) {
				add_bit(atom_syms[a][:], int(s))
			}
		}
		return s, true
	}
	if !charge(b, 128 * n) {
		return
	}
	for r in 0 ..< 128 {
		slice.zero(accepting)
		for &a, i in b.atoms {
			if has_bit(a.ascii[:], r) {
				add_bit(accepting, i)
			}
		}
		ascii[r] = symbol(b, &ids, atom_syms, accepting) or_return
	}
	// Past ASCII an atom's answer changes only where one of its runs begins or ends, so a sweep over those places in
	// order visits each run of characters that every atom answers alike.
	// An edge holds the character where it falls above ATOM_BITS, and the atom it turns on or off in the low ATOM_BITS.
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
	slice.sort(edges[:])
	runs := make([dynamic]rune)
	run_syms := make([dynamic]u8)
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
		if len(run_syms) == 0 || run_syms[len(run_syms) - 1] != s {
			append(&runs, at)
			append(&run_syms, s)
		}
		if k == len(edges) {
			break
		}
		at = rune(edges[k] >> ATOM_BITS)
	}
	return ascii, runs[:], run_syms[:], atom_syms, len(ids), true
}
