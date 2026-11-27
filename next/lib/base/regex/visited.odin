#+private
package regex

// The linear search's visited set.

import "base:intrinsics"
import "core:slice"

// The program's facts the visited set reads, kept behind a pointer since a Regex is copied.
Visited :: struct {
	owner:   []i32, // the look-ahead each instruction lies in, -1 for none, or nil for no look-ahead
	// The ECMA loops whose body may match empty, each one's mark slot and the loop around it (-1 for none), the
	// innermost each instruction lies in (-1 for none), and each instruction's first row of the visited set, the row
	// count last. An instruction has a row and one more for each loop around it, since an iteration that has matched
	// nothing yet fails where one that has goes on (`row_of`). Nil when no such loop.
	loops:   [][2]i32,
	loop_of: []i32,
	// The ECMA counter loops, the innermost each instruction lies in (-1 for none, nil for no loop), and each
	// instruction's rows for one count of the loops around it (`block`). An instruction has a block of rows for each
	// count of each loop around it, since what follows depends on the count. A program with counter loops has its
	// rows laid out for each search (`counted_rows`), the others here.
	counters:   []Counter,
	counter_of: []i32,
	block:      []int,
	rows:       []int,
}

// An ECMA counter loop's slot, its least and most counts, and the loop around it, -1 for none.
Counter :: struct {
	slot, least, most, outer: int,
}

// The visited set's rows of `re`'s program laid out with `rows`, one an instruction for nil.
total_rows :: proc(re: ^Regex, rows: []int) -> int {
	return rows[len(re.insts)] if rows != nil else len(re.insts)
}

// The rows of a program with counter loops over `places` places, each loop's count held to what it can reach there:
// past its least count an iteration that reads nothing fails, so each reads a character. And the rows it would have
// with one count of each loop.
counted_rows :: proc(re: ^Regex, places: int, scratch: ^Scratch) -> (rows, radix: []int, plain: int) {
	v := re.visited
	n := len(re.insts)
	resize(&scratch.held.rows, n + 1 + len(v.counters))
	if scratch.held.gate.failed {
		return nil, nil, 0
	}
	rows, radix = scratch.held.rows[:n + 1], scratch.held.rows[n + 1:]
	for c, k in v.counters {
		bound := c.most if places >= c.most - c.least else c.least + places
		radix[k] = min(bound, MAX_ROWS - 1) + 1
	}
	lay_out_rows(v, rows, radix)
	for block in v.block {
		plain += block
	}
	return
}

// An ECMA linear search resumes at most SEARCH_WORK alternatives for each pair of its rows, with one count of each
// counter loop, over its places, and no fewer than SEARCH_RESUMES. Each count of a counter loop multiplies the pairs,
// and each pair may resume a bounded repeat's every stop, so past this the search ends with BUDGET_OUT, undecided,
// and its time stays linear in the program and the text. Its sets under counter loops take at most COUNTED_BYTES with
// the stack.
SEARCH_WORK :: 4
SEARCH_RESUMES :: 1 << 25
COUNTED_BYTES :: 1 << 25

// The bytes a linear search of `re` with `rows` over `places` places may take beside its sets within `most`, negative
// when the sets alone pass it. A jq search past MAX_BYTES runs Oniguruma's way, with its retry limit, so the automaton
// answers a jq search only within it.
visited_room :: proc(re: ^Regex, rows, places: int, most := MAX_BYTES) -> int {
	return most - set_words(rows, places) * 8 * (2 if re.visited.owner != nil else 1)
}

// The visited set's row of instruction `pc` at `pos`, past its first one for each loop around it whose iteration has
// matched nothing up to `pos` (`Visited.rows`), in the block of the counts of the counter loops around it. Those loops
// are the innermost ones, since an iteration began no earlier than the one around it.
row_of :: #force_inline proc(m: ^Matcher, pc, pos: int) -> int {
	if m.rows == nil {
		return pc
	}
	v := m.re.visited
	row := m.rows[pc]
	for l := v.loop_of[pc]; l >= 0 && m.slots[v.loops[l][0]] == pos; l = v.loops[l][1] {
		row += 1
	}
	if m.radix != nil {
		row += v.block[pc] * counts_block(m, v, pc)
	}
	return row
}

// Which block of rows the counts of the counter loops around `pc` give it, the innermost count the lowest digit.
@(private = "file")
counts_block :: proc(m: ^Matcher, v: ^Visited, pc: int) -> int {
	block, times := 0, 1
	for l := int(v.counter_of[pc]); l >= 0; l = v.counters[l].outer {
		block += m.slots[v.counters[l].slot] * times
		times *= m.radix[l]
	}
	return block
}

// The row of a Rep's body past where the Rep began, where no loop's iteration has matched nothing.
stop_row :: #force_inline proc(m: ^Matcher, pc: int) -> int {
	if m.rows == nil {
		return pc + 1
	}
	if m.radix != nil {
		return m.rows[pc + 1] + m.re.visited.block[pc + 1] * counts_block(m, m.re.visited, pc + 1)
	}
	return m.rows[pc + 1]
}

// Marks the pair of `row` at `pos` as visited, or returns false when it already was. A pair visited inside a
// look-ahead is logged, for `settle`.
first_visit :: #force_inline proc(m: ^Matcher, row, pos: int) -> bool {
	bit := row * m.width + pos - m.lo
	if has_bit(m.seen, bit) {
		return false
	}
	add_bit(m.seen, bit)
	if m.looking > 0 {
		// `owner != nil` caps `seen` at MAX_BYTES / 2, so `bit < MAX_BYTES * 4 <= max(u32)`.
		#assert(MAX_BYTES * 4 <= max(u32))
		append(m.log, u32(bit))
	}
	return true
}

in_good :: #force_inline proc(m: ^Matcher, row, pos: int) -> bool {
	bit := row * m.width + pos - m.lo
	return has_bit(m.good, bit)
}

// A look-ahead's body matched: the pairs on the path it took match from there too, to whichever look-ahead reaches them
// next, and the log goes back to where the look-ahead began.
settle :: proc(m: ^Matcher, bar: Entry) {
	for bit in m.log[bar.b:] {
		add_bit(m.good, int(bit))
	}
	resize(m.log, int(bar.b))
	m.looking -= 1
}

// Each instruction's first row of the visited set into `rows`, the total last: its block, times the counts
// `radix` gives each counter loop around it. A total past MAX_ROWS is held at it.
lay_out_rows :: proc(v: ^Visited, rows: []int, radix: []int) {
	rows[0] = 0
	for block, pc in v.block {
		times := 1
		if radix != nil {
			for k := int(v.counter_of[pc]); k >= 0; k = v.counters[k].outer {
				times = min(sat_mul(times, radix[k]), MAX_ROWS)
			}
		}
		rows[pc + 1] = min(rows[pc] + min(sat_mul(block, times), MAX_ROWS), MAX_ROWS)
	}
}

// More rows than a visited set within MAX_BYTES holds over one place.
@(private = "file")
MAX_ROWS :: MAX_BYTES * 8 + 1

// `a` times `b`, held at the largest int.
sat_mul :: #force_inline proc "contextless" (a, b: int) -> int {
	product, overflowed := intrinsics.overflow_mul(a, b)
	return max(int) if overflowed else product
}

// The 64-bit words of a visited set of `rows` rows over `places` places, held at what an int counts.
set_words :: #force_inline proc "contextless" (rows, places: int) -> int {
	bits := sat_mul(rows, places)
	return bits / 64 + int(bits % 64 != 0)
}

// Whether a linear search with a visited set applies to a program. Under ECMA it does with a loop, a look-around, two
// choices, or one choice in a search that tries more than one start, and no back reference, whose outcome depends on
// the groups the way there set. Under jq it does with a choice inside a loop, the shape that backtracks past
// polynomial time, and only when each instruction's outcome depends on the position alone: no look-around, back
// reference, counter, call or callout, and no empty check, whose exit Oniguruma takes where ECMA fails.
linear_ops :: proc(insts: []Inst, ecma: bool, anchored: bool) -> bool {
	for ins in insts {
		allowed := ecma && ins.op != .Backref
		#partial switch ins.op {
		case .Match, .Str, .Char_Fold, .Any, .Any_All, .Class, .Split, .Split_Head, .Jmp, .Set, .Linebreak, .Rep,
		     .Rep_Lazy:
			allowed = true
		case .Save:
			allowed ||= ins.a != 0 && ins.b == 0 // not \K, nor a referenced group's start
		case .Assert:
			allowed ||= Assert_Kind(ins.a) < .Fail
		}
		if !allowed {
			return false
		}
	}
	choices := 0
	for ins, i in insts {
		if ecma {
			// A program that starts at one place and has one choice and no loop or look-ahead tries each alternative
			// of it along a straight line, so the visited set would only add work.
			choices += int(is_choice(ins))
			if ins.op == .Look || ins.op == .Count_Next || ins.op == .Jmp && int(ins.a) < i {
				return true
			}
		} else if ins.op == .Jmp && int(ins.a) < i && slice.any_of_proc(insts[ins.a + 1:i], is_choice) {
			return true
		}
	}
	return choices > 1 || choices == 1 && !anchored
}

@(private = "file")
is_choice :: proc(ins: Inst) -> bool {
	#partial switch ins.op {
	case .Split, .Split_Head, .Count, .Count_Lazy, .Look:
		return true
	case .Rep, .Rep_Lazy:
		return ins.a != ins.b
	}
	return false
}

// For each instruction, the look-ahead whose body it lies in (the innermost), or -1. Nil for none.
look_owners :: proc(insts: []Inst) -> []i32 {
	owner: []i32
	for ins, i in insts {
		if ins.op != .Look {
			continue
		}
		if owner == nil {
			owner = make([]i32, len(insts))
			if len(owner) < len(insts) {
				return nil
			}
			slice.fill(owner, -1)
		}
		for k in i + 1 ..= int(ins.b) {
			owner[k] = i32(i)
		}
	}
	return owner
}
