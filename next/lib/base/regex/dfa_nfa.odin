#+private
package regex

// Program-to-item lowering and epsilon-closure engine for the automaton builder in dfa_build.odin.

import "core:slice"
import "core:unicode/utf8"

@(private = "file")
DFA_MAX_LOOKS :: 8 // leading look-aheads, each a component of the product's states

// The atom of an item that is the program's Match, which no character test accepts.
MATCH_ITEM :: -1

Item :: struct {
	pc, k, atom: i32, // instruction, Rep count or Str char index, and atom id or MATCH_ITEM
}

// A look-ahead the program begins with. The product runs an automaton of its body from the text's start.
Leading_Look :: struct {
	body:     i32, // the body's first instruction
	negative: bool,
}

Builder :: struct {
	using atoms_ctx: Atoms,
	base:            []i32, // each instruction's first item, -1 for none
	items:           [dynamic]Item,
	after:           [][]u32, // each reading item's threads after it reads
	// The items a thread at an instruction reaches before the next character, keyed by the instruction and the classes
	// on either side. Match is one of the items.
	closures:        map[u32][]u32,
	lines:           bool, // the program has `^` or `$` of a line
	word:            bool, // the program has `\b` or `\B` of Unicode word characters
	ascii_word:      bool, // of ASCII ones
	semi_end:        bool, // the program has `\Z`, or `$` outside a multiline pattern
	empty_loops:     bool, // the program has a loop whose body can match empty
	keeps:           bool, // the program has `\K`
	asserts:         bool, // the program has an assertion, without which a closure reads no class
	used:            [CLASSES]bool, // the classes a character after a place can have, the text's end among them
	restart_dies:    bool, // a thread at the program's start reaches nothing past the text's start
	looks:           [dynamic]Leading_Look, // the look-aheads the program begins with (`leading_looks`)
	stamp:           u32,
	in_set:          []u32, // the stamp of the set that last held each thread
	walk:            u32,
	pc_seen:         []u32, // the walk number of the closure that last reached each instruction
	item_seen:       []u32, // the walk number of the closure that last took each item
	todo:            [dynamic]int,
	row_key:         [dynamic]u32,
}

// Returns class `c` of the character before a place, reduced to the classes the program's assertions read. A class
// none of them reads (including FINAL, which no assertion distinguishes before a place) becomes OTHER, and EDGE stays.
seen_class :: proc(b: ^Builder, c: int) -> int {
	if c == EDGE || c == NEWLINE && b.lines || c == WORD && (b.word || b.ascii_word) {
		return c
	}
	return OTHER
}

// Collects the look-aheads an ECMA program begins with after `^` into `b.looks`. False for a program with a look-around
// anywhere else. Anchored at the text's start, each look-ahead tests a prefix of the text, which a product of automata
// runs. The program's own automaton skips them.
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
// from the minimum on reuses the last item. False for a program the automaton does not run.
enumerate_items :: proc(b: ^Builder) -> bool {
	re := b.re
	insts := re.insts
	charge(b, len(insts)) or_return
	b.base = make([]i32, len(insts))
	slice.fill(b.base, -1)
	charge(b, 0) or_return
	rep_body := false
	for ins, pc in insts {
		if rep_body {
			rep_body = false
			continue
		}
		first := i32(len(b.items))
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
				b.lines = true
			case .Word_Boundary, .Not_Word_Boundary:
				b.word = true
			case .Ascii_Boundary, .Not_Ascii_Boundary:
				b.ascii_word = true
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
			count := max(int(ins.a), 1) if ins.b < 0 else int(ins.b)
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
		if len(b.items) > DFA_MAX_ITEMS {
			return false
		}
	}
	return !(b.word && b.ascii_word)
}

@(private = "file")
add_items :: proc(b: ^Builder, pc, count: int, atom: i32, k := 0) {
	for j in 0 ..< count {
		append(&b.items, Item{i32(pc), i32(k + j), atom})
	}
}

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

// Fills `set` with the reading items `threads` reach, in order, between a character of class `before` and one of class
// `after`, and returns whether Match is among what they reach. With `$stop` the reach ends at the first Match, since
// the threads after it are ones the backtracker would try only if that match failed.
expand :: proc(
	b: ^Builder,
	set: ^[dynamic]u32,
	threads: []u32,
	before, after: int,
	$stop: bool,
) -> (
	matched: bool,
	ok: bool,
) {
	n := len(b.items)
	b.stamp += 1
	clear(set)
	walk: for x in threads {
		if int(x) < n {
			add_item(b, set, x)
			continue
		}
		reach := closure_of(b, int(x) - n, before, after) or_return
		charge(b, len(reach)) or_return
		for it in reach {
			if b.items[it].atom == MATCH_ITEM {
				matched = true
				when stop {
					break walk
				}
			} else {
				add_item(b, set, it)
			}
		}
	}
	return matched, true
}

// Returns the threads after reading item `it`'s character, in the order of their alternatives: the next item of the
// same instruction, or a thread at the instruction that follows.
after_read :: proc(b: ^Builder, it: int) -> []u32 {
	n := len(b.items)
	pc, k := int(b.items[it].pc), int(b.items[it].k)
	ins := b.re.insts[pc]
	out := make([dynamic]u32, 0, 2)
	#partial switch ins.op {
	case .Str:
		if it + 1 < n && int(b.items[it + 1].pc) == pc {
			append(&out, u32(it + 1))
		} else {
			append(&out, u32(n + pc + 1))
		}
	case .Rep, .Rep_Lazy:
		count := k + 1
		if ins.b < 0 {
			append(&out, u32(int(b.base[pc]) + min(count, max(int(ins.a) - 1, 0))))
		} else if count < int(ins.b) {
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
