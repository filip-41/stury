#+private
package regex

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
	resize(&scratch.rows, n + 1 + len(v.counters))
	rows, radix = scratch.rows[:n + 1], scratch.rows[n + 1:]
	for c, k in v.counters {
		radix[k] = min(c.most, c.least + places) + 1
	}
	lay_out_rows(v, rows, radix)
	for block in v.block {
		plain += block
	}
	return
}

// An ECMA linear search resumes at most SEARCH_WORK alternatives for each pair of its rows, with one count of each
// counter loop, over its places, and no fewer than SEARCH_RESUMES. Each count of a counter loop multiplies the pairs,
// and each pair may resume a bounded repeat's every stop, so past this the search ends with MEMORY_ERROR, undecided,
// and its time stays linear in the program and the text. Its sets under counter loops take at most COUNTED_BYTES with
// the stack.
SEARCH_WORK :: 4
SEARCH_RESUMES :: 1 << 25
COUNTED_BYTES :: 1 << 25

// The bytes a linear search of `re` with `rows` over `places` places may take beside its sets within `most`, negative
// when the sets alone pass it. A jq search past MAX_BYTES runs Oniguruma's way, with its retry limit, so the automaton
// answers a jq search only within it.
visited_room :: proc(re: ^Regex, rows, places: int, most := MAX_BYTES) -> int {
	return most - (rows * places + 63) / 64 * 8 * (2 if re.visited.owner != nil else 1)
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
	word, mask := bit >> 6, u64(1) << (u64(bit) & 63)
	if m.seen[word] & mask != 0 {
		return false
	}
	m.seen[word] |= mask
	if m.looking > 0 {
		append(m.log, u32(bit))
	}
	return true
}

in_good :: #force_inline proc(m: ^Matcher, row, pos: int) -> bool {
	bit := row * m.width + pos - m.lo
	return m.good[bit >> 6] & (1 << (u64(bit) & 63)) != 0
}

// A look-ahead's body matched: the pairs on the path it took match from there too, to whichever look-ahead reaches them
// next, and the log goes back to where the look-ahead began.
settle :: proc(m: ^Matcher, bar: Entry) {
	for bit in m.log[bar.b:] {
		m.good[bit >> 6] |= 1 << (u64(bit) & 63)
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
				times = min(times * radix[k], MAX_ROWS)
			}
		}
		rows[pc + 1] = min(rows[pc] + block * times, MAX_ROWS)
	}
}

// More rows than a visited set within MAX_BYTES holds over one place.
MAX_ROWS :: MAX_BYTES * 8 + 1
