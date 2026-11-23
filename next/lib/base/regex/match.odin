package regex

// The backtracking matcher and the search entry point. The matcher tries a program's alternatives in order as
// Oniguruma does, so its matches and captures are Oniguruma's. After ten million backtracks at one start it gives
// up with an error (ONIG_DEFAULT_RETRY_LIMIT_IN_MATCH). Its stack is capped, where Oniguruma's grows without bound.
// `search` asks the automata of dfa.odin first where they can answer.

import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

@(private)
MAX_RETRIES :: 10_000_000 // ONIG_DEFAULT_RETRY_LIMIT_IN_MATCH. Past it the match errors, as Oniguruma's does, when the caller gives no step budget
@(private)
MAX_STACK :: 1 << 23 // entries, 24 bytes each
@(private)
KEEP_BYTES :: 1 << 20 // scratch grown past this is freed after the search rather than kept
@(private)
MAX_CALL_NEST :: 20 // Oniguruma's subexp_call_nest_counter limit as jq builds it, a group in place counted

// Why a search gave up. `Steps` is the caller's step budget, or the engine's own limit on the work of a search when the
// caller gave none. `Memory` is the cap on what a search may hold. `Callout` is an error that a pattern's callout ends
// the search with. `message` is Oniguruma's.
Error_Kind :: enum u8 {
	None,
	Steps,
	Memory,
	Callout,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

@(private)
STEPS_OUT :: Error{.Steps, "retry-limit-in-match over"}
@(private)
BUDGET_OUT :: Error{.Steps, MEMORY_ERROR}
@(private)
MEMORY_OUT :: Error{.Memory, MEMORY_ERROR}

@(private)
Entry_Kind :: enum u8 {
	Branch, // resume at pc, position a
	Restore, // slot a had value b
	Barrier, // the Look at pc began at position a
	Give_Back, // a greedy Rep at pc stopped at a, and may give back to b
	Take_More, // a lazy Rep at pc stopped at a after b runes, and may take more
	Retract, // the callout of data a was passed, and counts as the match backs past it (`retract`)
	Call_Frame, // a call returns to pc
	Return, // a call returned
	Mem_Start, // group a of a recursion began at position b
	Mem_End, // group a of a recursion ended
	Limit, // the limit was a
}

// The entry kinds that the end of a look or atomic group keeps from its body: all but the alternatives.
@(private = "file")
KEPT :: bit_set[Entry_Kind]{.Restore, .Retract, .Call_Frame, .Return, .Mem_Start, .Mem_End, .Limit}

@(private)
Entry :: struct {
	kind: Entry_Kind,
	pc:   i32,
	a, b: int,
}

// The matcher's stack and slots. A caller keeps one for its next search, and two searches running at once must not
// share one. It allocates from `allocator` as it grows and `scratch_destroy` frees it.
Scratch :: struct {
	allocator: mem.Allocator,
	stack:  [dynamic]Entry,
	slots:  [dynamic]int,
	counts: [dynamic]int,
	seen:   [dynamic]u64, // a linear search's visited pairs, one bit per instruction and position, or the counting search's sets
	good:   [dynamic]u64, // the pairs inside a look-ahead whose body is known to match from there
	log:    [dynamic]u32, // the pairs first visited on the way through the look-aheads being matched
	rows:   [dynamic]int, // under counter loops, the visited set's rows and then each loop's counts (`counted_rows`), or the counting search's layout
	resumes: int, // the alternatives the last linear search resumed, which its program and text bound
	spent:   int, // the steps the last search took, backtracks and automaton set words, which a caller charges to its budget
	ends:    int, // where the automaton found the last search's match to end, -1 when it did not or found none
}

scratch_make :: proc(allocator: mem.Allocator) -> Scratch {
	return {allocator = allocator}
}

scratch_destroy :: proc(scratch: ^Scratch) {
	delete(scratch.stack)
	delete(scratch.slots)
	delete(scratch.counts)
	delete(scratch.seen)
	delete(scratch.good)
	delete(scratch.log)
	delete(scratch.rows)
	scratch^ = {}
}

@(private)
Matcher :: struct {
	re:       ^Regex,
	s:        string,
	start:    int, // where the search began, for \G
	slots:    []int,
	stack:    ^[dynamic]Entry,
	retries:  int,
	cap:      int, // the most retries the run at this start may take
	spent:    int, // the retries of the runs before this start
	allowed:  int, // under a step budget, the retries the runs may take in all, otherwise -1
	err:      Error,
	caps:     []int,
	best_len: int, // under `longest`, the longest match so far
	keep:     int, // under `longest`, where the last match at this start kept from (\K)
	skip:     int, // the furthest position a (*SKIP) reached, before which the next start may not be
	counts:   []int, // each callout's count (`Callout`)
	limit:    int, // the end of the text the match reads to, short of its end within an absent operator
	depth:    int, // calls not returned from
	behind:   Grapheme_Behind,
	seen, good: []u64, // under `Regex.linear`, good only for a program with a look-ahead
	rows:     []int, // under `Regex.linear`, each instruction's first row of the visited set, nil when each has one
	radix:    []int, // under counter loops, the counts each loop's count is held to
	budget:   int, // under `Regex.linear`, the alternatives the search may resume (`SEARCH_WORK`)
	log:      ^[dynamic]u32,
	looking:  int, // the look-aheads being matched, under `Regex.linear`
	room:     int, // under `Regex.linear`, the bytes the stack and the log may take beside the sets
	// Under `Regex.linear`, the sets hold the places from `lo` on, `width` places a row. `first_start` and `last_start`
	// are the first and last start a match can have.
	lo, width, first_start, last_start: int,
}

// Finds the first match of `re` in `s` at or after byte `start`. `caps` receives the groups' byte bounds, 2 per group
// with the whole match first, -1 for a group that did not take part. `err` says why the search gave up, with
// Oniguruma's message. With no `caps` it only reports whether there is a match.
//
// `steps` is the most work the search may do, counted in backtracks and in the automaton's set words, and `err.kind` is
// `.Steps` when it runs out, with the match undecided. Without it (0) the search keeps to Oniguruma's own retry limit
// at each start, and the limits on the other searches that `MAX_RETRIES` and the constants of visited.odin and
// counting.odin give.
search :: proc(re: ^Regex, s: string, start: int, caps: []int, scratch: ^Scratch, steps := 0) -> (found: bool, err: Error) {
	context.allocator = scratch.allocator
	scratch.ends, scratch.resumes, scratch.spent = -1, 0, 0
	limited := steps > 0
	left := steps

	// Oniguruma's search gives up past its retry limit where the automata would still answer. So under jq they answer
	// only where the visited set runs the program, which never gives up, or where no start can take that many retries.
	jq_automaton := !re.ecma && re.dfa != nil && !re.longest && !re.not_empty && !re.calls_or_limits
	jq_automaton &&= visited_room(re, total_rows(re, re.visited.rows), len(s) + 1) >= 0 if re.linear else retries_bounded(re.dfa, len(s) - min(start, len(s)), steps if limited else MAX_RETRIES)
	// Under jq the automata start at Oniguruma's first start, which its optimizer can place past a match. The starts it
	// skips after that cannot have a match, but when it searches windows of starts in turn (`high < last` in
	// `try_starts`) the backtracker does the search.
	from := start
	if re.narrowed && start <= len(s) && jq_automaton {
		first, last, _, high, ok := search_starts(re.opt, s, start)
		if !ok {
			return false, {}
		}
		from = first if high >= last else -1
	}
	if len(caps) == 0 && re.dfa != nil && (re.ecma || jq_automaton) && from >= 0 {
		if hit, judged := dfa_search(re.dfa, s, from); judged {
			return hit, {}
		}
	}
	counted, decided, work := count_search(re, s, start, caps, scratch, false, left if limited else COUNTING_WORK)
	if decided {
		scratch.spent = work
		return counted, {}
	}
	if limited {
		if left -= work; left < 0 {
			scratch.spent = work
			return false, STEPS_OUT
		}
	}
	spent := work
	// The automata give where the match ends and starts and how far a search reads. The backtracker then runs only at
	// that start, for the groups, and its visited set covers only that range.
	lo, width, first_start, last_start := 0, len(s) + 1, 0, len(s)
	if len(caps) > 0 && (jq_automaton || re.ecma && re.dfa != nil) && re.dfa.first != nil && from >= 0 {
		if end, reach, judged := dfa_first(re.dfa, s, from); judged {
			if end < 0 {
				return false, {}
			}
			lo, width, last_start = from, reach - from + 1, end
			scratch.ends = end
			if begin, known := dfa_start(re.dfa, s, from, end); known {
				if len(caps) == 2 {
					caps[0], caps[1] = begin, end
					return true, {}
				}
				lo, width, first_start, last_start = begin, reach - begin + 1, begin, begin
			}
		}
	}
	defer shrink(&scratch.stack)
	resize(&scratch.slots, re.slots)
	resize(&scratch.counts, len(re.callouts))
	m := Matcher{re = re, s = s, start = start, slots = scratch.slots[:], counts = scratch.counts[:], stack = &scratch.stack, caps = caps, best_len = -1, limit = len(s), lo = lo, width = width, first_start = first_start, last_start = last_start, allowed = left if limited else -1, cap = left if limited else MAX_RETRIES}
	slice.zero(m.counts)
	// The visited set is bounded by the text, so the memory cap replaces the retry limit and the jq stack cap. The set
	// persists across starts, so a search where a pair's outcome depends on the start (`longest`, `not_empty`) runs
	// without it, and so does a jq program whose set would pass the cap.
	linear := re.linear && !re.longest && !re.not_empty
	words: int
	if linear {
		m.rows, m.radix = re.visited.rows, nil
		plain, most := total_rows(re, m.rows), MAX_BYTES
		if re.visited.counters != nil {
			m.rows, m.radix, plain = counted_rows(re, len(s) + 1, scratch)
			most = COUNTED_BYTES
		}
		m.budget = left if limited else max(SEARCH_RESUMES, sat_mul(sat_mul(SEARCH_WORK, plain), width)) if re.ecma else max(int)
		rows := total_rows(re, m.rows)
		words = set_words(rows, width)
		m.room = visited_room(re, rows, len(s) + 1, most)
		if m.room < 0 && re.ecma {
			counted, decided, work = count_search(re, s, start, caps, scratch, true, left if limited else COUNTING_WORK)
			scratch.spent = spent + work
			if decided {
				return counted, {}
			}
			return false, MEMORY_OUT
		}
		linear = m.room >= 0
	}
	if linear {
		resize(&scratch.seen, words)
		slice.zero(scratch.seen[:])
		m.seen = scratch.seen[:]
		if re.visited.owner != nil {
			resize(&scratch.good, words)
			slice.zero(scratch.good[:])
			m.good = scratch.good[:]
		}
		clear(&scratch.log)
		m.log = &scratch.log
	}
	defer if linear {
		shrink(&scratch.seen)
		shrink(&scratch.good)
		shrink(&scratch.log)
	}
	defer {
		scratch.resumes = m.retries
		scratch.spent = spent + m.spent + m.retries
	}
	switch {
	case re.calls_or_limits:
		return try_starts(&m, true, false)
	case linear:
		found, err = try_starts(&m, false, true)
	case:
		found, err = try_starts(&m, false, false)
	}
	if err.kind != .None {
		if counted, decided, _ = count_search(re, s, start, caps, scratch, true, left - m.spent - m.retries if limited else COUNTING_WORK); decided {
			return counted, {}
		}
	}
	return found, err
}

// The counting search's answer to a search of an ECMA program with counted repeats that reads no bounds: `after`
// false for a program with counter loops, before the backtracker, and true for one without, once the backtracker gave
// up. `judged` is false when it does not run or does not decide. `work` is the set words it read, which it holds to
// `limit`.
@(private = "file")
count_search :: proc(re: ^Regex, s: string, start: int, caps: []int, scratch: ^Scratch, after: bool, limit: int) -> (found, judged: bool, work: int) {
	if len(caps) > 0 || re.counting == nil || re.counting.loops == after {
		return
	}
	found, judged, work = counting_search(re, s, start, scratch, limit)
	shrink(&scratch.seen)
	return
}

// Frees `a` when its capacity passes KEEP_BYTES, instead of keeping it for the next search.
@(private = "file")
shrink :: proc(a: ^[dynamic]$T) {
	if cap(a) * size_of(T) > KEEP_BYTES {
		allocator := a.allocator
		delete(a^)
		a^ = nil
		a.allocator = allocator
	}
}

@(private = "file")
try_starts :: proc(m: ^Matcher, $EXT, $SET: bool) -> (found: bool, err: Error) {
	re, s, start := m.re, m.s, m.start
	first, last, limit, high := start, len(s), len(s), INFINITE_LEN
	if re.narrowed {
		ok: bool
		if first, last, limit, high, ok = search_starts(re.opt, s, start); !ok {
			return false, {}
		}
	}
	first, last = max(first, m.first_start), min(last, m.last_start)
	// A string or map the optimizer finds at a bounded distance gives each window of starts, low to high, a match
	// holding it there can have. Other searches try every start in a single window.
	windowed := high < last
	at := first
	starts: for at <= last {
		end := last
		if windowed {
			if at = next_window(re.opt, s, at, limit, &high); at < 0 {
				break
			}
			end = min(high, last)
		}
		for at <= end {
			#partial switch h := re.head; h.kind {
			case .Exact:
				k := strings.index(s[at:], h.exact)
				if k < 0 {
					break starts
				}
				at += k
			case .Map:
				for at < len(s) && !has_bit(h.set[:], int(s[at])) {
					at += lead_width(s[at])
				}
				if at >= len(s) {
					break starts
				}
			}
			if at > end {
				break
			}
			if run(m, at, EXT, SET) {
				return true, {}
			}
			if m.err.kind != .None {
				return false, m.err
			}
			if at >= len(s) {
				break starts
			}
			at = max(at + lead_width(s[at]), m.skip)
		}
		if !windowed {
			break
		}
	}
	return m.best_len >= 0, {}
}

// Returns the bytes Oniguruma steps over from lead byte `b` to the next place a search tries. A continuation byte,
// where jq's global search can start inside a character, gives 1.
@(private)
lead_width :: #force_inline proc(b: byte) -> int {
	switch {
	case b < 0xC0:
		return 1
	case b < 0xE0:
		return 2
	case b < 0xF0:
		return 3
	case b < 0xF8:
		return 4
	}
	return 1
}

// Returns the character at `pos` and its width. A byte below 0xC0 is read as the code point of its value, as Oniguruma
// reads a continuation byte where jq's global search starts inside a character.
@(private)
decode :: #force_inline proc(s: string, pos: int) -> (rune, int) {
	if s[pos] < 0xC0 {
		return rune(s[pos]), 1
	}
	return utf8.decode_rune_in_string(s[pos:])
}

// Returns the position after what the Str, Any, Any_All, Class or Char_Fold instruction `ins` matches at `pos`, or -1.
@(private)
step :: #force_inline proc(re: ^Regex, ins: Inst, s: string, pos: int) -> int {
	if pos >= len(s) {
		return -1
	}
	#partial switch ins.op {
	case .Str:
		lit := re.bytes[ins.a:][:ins.b]
		return pos + len(lit) if strings.has_prefix(s[pos:], lit) else -1
	case .Any:
		if s[pos] == '\n' {
			return -1
		}
		_, w := decode(s, pos)
		return pos + w
	case .Any_All:
		_, w := decode(s, pos)
		return pos + w
	case .Class:
		cls := re.classes[ins.a]
		r, w := decode(s, pos)
		if w == 1 && r >= 0x80 && !word_type(cls) {
			// A lone continuation byte, after an empty match: Oniguruma's bracket classes match it only negated.
			return pos + 1 if cls.negated else -1
		}
		return pos + w if class_match(cls, r) else -1
	case .Char_Fold:
		r, w := decode(s, pos)
		return pos + w if fold(r) == rune(ins.a) else -1
	}
	return -1
}

@(private = "file")
push :: #force_inline proc(m: ^Matcher, e: Entry) {
	append(m.stack, e)
}

// Pushes an alternative. At MAX_STACK entries it sets Oniguruma's error and returns false. With `$SET` it sets the
// memory error instead once the stack and the log may take `m.room` bytes, the room beside the sets. An array's
// capacity is at most twice its length, and the log grows by at most a program's length between two pushes.
@(private)
push_branch :: #force_inline proc(m: ^Matcher, e: Entry, $SET: bool) -> bool {
	when SET {
		if 2 * (len(m.stack) * size_of(Entry) + len(m.log) * size_of(u32)) >= m.room {
			m.err = MEMORY_OUT
			return false
		}
	} else {
		if len(m.stack) >= MAX_STACK {
			m.err = {.Memory, "match-stack limit over"}
			return false
		}
	}
	append(m.stack, e)
	return true
}

// Runs the program from `at`: true on a match (written to m.caps), false on none or on an error in m.err.
@(private = "file")
run :: proc(m: ^Matcher, at: int, $EXT, $SET: bool) -> bool {
	re, s := m.re, m.s
	insts := re.insts
	slots := m.slots
	slice.fill(slots, -1)
	slots[0] = at
	for c, i in re.callouts {
		if c.kind != .Total_Count {
			m.counts[i] = 0 // Oniguruma clears a callout's data at each start, except TOTAL_COUNT's
		}
	}
	clear(m.stack)
	when SET {
		m.looking = 0
	} else {
		if m.retries != 0 {
			m.spent += m.retries
			m.retries = 0
			if m.allowed >= 0 {
				m.cap = m.allowed - m.spent
			}
		}
	}
	when EXT {
		m.limit, m.depth = len(m.s), 0
	}
	pc, pos := 0, at
	m.keep = at
	for {
		ins := insts[pc]
		ok := true
		when SET {
			if row := row_of(m, pc, pos); !first_visit(m, row, pos) {
				// A pair that a look-ahead's body is known to match from continues at the body's end. When the caller
				// reads groups and the body holds some, the path is run again instead, since the groups it sets are the
				// result. The pairs on it are all known by then.
				ins = {op = .Seen}
				if m.good != nil && in_good(m, row, pos) {
					look := int(re.visited.owner[pc])
					if insts[look + 1].op != .Unset || len(m.caps) <= 2 {
						pc = int(insts[look].b)
					}
					ins = insts[pc]
				}
			}
		}
		switch ins.op {
		case .Seen:
			ok = false
		case .Match:
			if re.not_empty && pos == at {
				ok = false
				break
			}
			// A \K in a look-ahead may keep past the end, where Oniguruma starts the match at its end.
			if !re.longest {
				if len(m.caps) > 0 {
					copy(m.caps, slots[:len(m.caps)])
					m.caps[0], m.caps[1] = min(m.caps[0], pos), pos
				}
				return true
			}
			// Oniguruma uses the latest \K on the stack, or where the last match at this start kept from when
			// there is none (UPDATE_VAR_KEEP_FROM_STACK_LAST), as it backtracks for a longer match.
			kept := slots[0] != at || m.keep == at
			for k := len(m.stack) - 1; !kept && k >= 0; k -= 1 {
				kept = m.stack[k].kind == .Restore && m.stack[k].a == 0
			}
			if kept {
				m.keep = slots[0]
			}
			if pos - at > m.best_len {
				m.best_len = pos - at
				if len(m.caps) > 0 {
					copy(m.caps, slots[:len(m.caps)])
					m.caps[0], m.caps[1] = min(m.keep, pos), pos
				}
			}
			ok = false
		case .Str:
			if ins.b == 1 {
				ok = pos < len(s) && s[pos] == re.bytes[ins.a]
				pos += 1
			} else {
				lit := re.bytes[ins.a:][:ins.b]
				ok = strings.has_prefix(s[pos:], lit)
				pos += len(lit)
			}
			pc += 1
		case .Any, .Any_All, .Class, .Char_Fold:
			next := step(re, ins, s, pos)
			ok = next >= 0
			pos = next
			pc += 1
		case .Split:
			push_branch(m, {kind = .Branch, pc = ins.b, a = pos, b = len(m.log) when SET else 0}, SET) or_return
			pc = int(ins.a)
		case .Split_Head:
			if pos >= len(s) || s[pos] != byte(ins.a) {
				pc = int(ins.b)
				continue
			}
			push_branch(m, {kind = .Branch, pc = ins.b, a = pos, b = len(m.log) when SET else 0}, SET) or_return
			pc += 1
		case .Jmp:
			pc = int(ins.a)
		case .Save:
			push(m, {kind = .Restore, a = int(ins.a), b = slots[ins.a]})
			slots[ins.a] = pos
			if ins.b != 0 {
				// Oniguruma pushes a referenced group's start (OP_MEM_START_PUSH), which unsets its end until
				// the group closes again. A backreference or condition inside the group sees it unset, and never
				// a start past the last iteration's end.
				push(m, {kind = .Restore, a = int(ins.a) + 1, b = slots[ins.a + 1]})
				slots[ins.a + 1] = -1
			}
			pc += 1
		case .Set:
			slots[ins.a] = pos
			pc += 1
		case .Assert:
			kind := Assert_Kind(ins.a)
			if kind == .Mismatch {
				return false
			}
			if kind == .Skip {
				m.skip = max(m.skip, pos)
			}
			if kind < .Error {
				ok = assert_at(m, kind, pos)
			} else {
				end: bool
				ok, end = callout(m, int(ins.b))
				if end {
					return false
				}
			}
			pc += 1
		case .Backref:
			next := backref(m, ins, pos)
			ok = next >= 0
			pos = next
			pc += 1
		case .Look:
			push(m, {kind = .Barrier, pc = i32(pc), a = pos, b = len(m.log) when SET else 0})
			when SET {
				m.looking += 1
			}
			pc += 1
		case .Look_End:
			k := len(m.stack) - 1
			for m.stack[k].kind != .Barrier {
				k -= 1
			}
			bar := m.stack[k]
			when SET {
				settle(m, bar)
			}
			switch Look_Kind(insts[bar.pc].a) {
			case .Not_Ahead, .Not_Behind:
				// The body matched, so the assertion fails: undo the body and fail past it.
				for len(m.stack) > k {
					undo(m, pop(m.stack), EXT)
				}
				ok = false
			case .Ahead, .Behind, .Atomic:
				// Drops the body's alternatives and keeps what it captured, which is undone when the match backs past
				// it.
				w := k
				for j in k + 1 ..< len(m.stack) {
					if m.stack[j].kind in KEPT {
						m.stack[w] = m.stack[j]
						w += 1
					}
				}
				resize(m.stack, w)
				// A look-behind continues where its body ends. Oniguruma's look-behind of one length does not
				// restore the position, which leaves it where it began, or past that when it began within a
				// character. ECMA's matches leftwards, so it is restored.
				if kind := Look_Kind(insts[bar.pc].a); kind == .Ahead || kind == .Behind && re.ecma {
					pos = bar.a
				}
				pc += 1
			}
		case .Back:
			for _ in 0 ..< ins.a {
				if pos == 0 {
					ok = false
					break
				}
				pos = char_start(s, pos - 1)
			}
			pc += 1
		case .Check:
			if slots[ins.a] != pos {
				pc += 1
			} else if ins.b >= 0 {
				pc = int(ins.b)
			} else {
				ok = false
			}
		case .Unset:
			unset_slots(m, ins)
			pc += 1
		case .Cond:
			pc = pc + 1 if slots[2 * ins.a + 1] >= 0 else int(ins.b)
		case .Linebreak:
			// Oniguruma's \R is (?>\r\n|[\n\v\f\r\x{85}\x{2028}\x{2029}]), whose second alternative costs a retry.
			next := linebreak(s, pos)
			if next != pos + 2 || s[pos] != '\r' {
				m.retries += 1
			}
			ok = next >= 0
			pos = next
			pc += 1
		case .Grapheme:
			next := grapheme(s, pos, &m.behind)
			ok = next >= 0
			pos = next
			pc += 1
		case .Rep, .Rep_Lazy:
			one := insts[pc + 1]
			count, p := 0, pos
			for count < int(ins.a) {
				if p = step(re, one, s, p); p < 0 {
					break
				}
				count += 1
			}
			if p < 0 {
				ok = false
				break
			}
			if ins.op == .Rep_Lazy {
				if ins.b < 0 || count < int(ins.b) {
					push(m, {kind = .Take_More, pc = i32(pc), a = p, b = count})
				}
			} else {
				lo := p
				// With `$SET` an unbounded repeat marks each stop past where it began in its body's row, which `run`
				// never visits. It walks no further than a stop an earlier walk marked, because that walk tries the
				// stops from there. Past where it began, no loop iteration has matched nothing, so the row is the
				// first.
				row := stop_row(m, pc) if SET else 0
				_ = row
				when SET {
					if ins.b < 0 && p > pos && !first_visit(m, row, p) {
						ok = false
						break
					}
				}
				for ins.b < 0 || count < int(ins.b) {
					next := step(re, one, s, p)
					if next < 0 {
						break
					}
					when SET {
						if ins.b < 0 && !first_visit(m, row, next) {
							break
						}
					}
					p = next
					count += 1
				}
				if p > lo {
					push(m, {kind = .Give_Back, pc = i32(pc), a = p, b = lo})
				}
				if count < int(ins.b) {
					// Oniguruma keeps an alternative for each optional copy it tries, so the copy that does
					// not match costs it a retry.
					m.retries += 1
				}
			}
			pos = p
			pc += 2
		case .Count_Reset:
			push(m, {kind = .Restore, a = int(ins.a), b = slots[ins.a]})
			slots[ins.a] = 0
			pc += 1
		case .Count, .Count_Lazy:
			k, bounds := slots[ins.a], insts[pc + 1]
			if k < int(bounds.a) {
				pc += 2
				break
			}
			if k >= int(bounds.b) {
				pc = int(ins.b)
				break
			}
			push_branch(m, {kind = .Branch, pc = ins.b if ins.op == .Count else i32(pc + 2), a = pos, b = len(m.log) when SET else 0}, SET) or_return
			pc = pc + 2 if ins.op == .Count else int(ins.b)
		case .Count_Next:
			push(m, {kind = .Restore, a = int(ins.a), b = slots[ins.a]})
			slots[ins.a] += 1
			pc = int(ins.b)
		case .Count_Check:
			loop := insts[ins.b]
			if slots[ins.a] != pos || slots[loop.a] < int(insts[ins.b + 1].a) {
				pc += 1
			} else {
				ok = false
			}
		case .Call, .Return, .Mem_Start, .Mem_End, .Limit_Save, .Limit_Cut, .Limit_Restore, .Limit_Clear:
			when EXT {
				ok = call_or_limit(m, ins, &pc, pos)
				s = m.s[:m.limit]
			} else {
				unreachable()
			}
		}
		if !ok {
			if !backtrack(m, &pc, &pos, EXT, SET) {
				return false
			}
			when EXT {
				s = m.s[:m.limit]
			}
		}
	}
}

@(private = "file")
unset_slots :: proc(m: ^Matcher, ins: Inst) {
	for k in ins.a ..< ins.b {
		if m.slots[k] >= 0 {
			push(m, {kind = .Restore, a = int(k), b = m.slots[k]})
			m.slots[k] = -1
		}
	}
}

// Executes the ops of subexpression calls and the absent operator. They are kept out of `run`'s loop so that patterns
// without them (`Regex.calls_or_limits` false) run with no tracking for them.
@(private = "file")
call_or_limit :: #force_no_inline proc(m: ^Matcher, ins: Inst, pc: ^int, pos: int) -> bool {
	slots := m.slots
	#partial switch ins.op {
	case .Call:
		if m.depth >= MAX_CALL_NEST {
			return false
		}
		m.depth += 1
		push(m, {kind = .Call_Frame, pc = i32(pc^ + 1)})
		pc^ = int(ins.a)
	case .Return:
		pc^ = int(latest_open(m.stack[:], .Call_Frame, .Return, 0).pc)
		m.depth -= 1
		push(m, {kind = .Return})
	case .Mem_Start:
		g := int(ins.a)
		push(m, {kind = .Restore, a = 2 * g, b = slots[2 * g]})
		push(m, {kind = .Restore, a = 2 * g + 1, b = slots[2 * g + 1]})
		slots[2 * g], slots[2 * g + 1] = pos, -1
		push(m, {kind = .Mem_Start, a = g, b = pos})
		pc^ += 1
	case .Mem_End:
		// The start of this group's own run, skipping the starts and ends of runs it called.
		g := int(ins.a)
		start := latest_open(m.stack[:], .Mem_Start, .Mem_End, g).b
		push(m, {kind = .Restore, a = 2 * g, b = slots[2 * g]})
		push(m, {kind = .Restore, a = 2 * g + 1, b = slots[2 * g + 1]})
		slots[2 * g], slots[2 * g + 1] = start, pos
		push(m, {kind = .Mem_End, a = g})
		pc^ += 1
	case .Limit_Save:
		push(m, {kind = .Restore, a = int(ins.a), b = slots[ins.a]})
		slots[ins.a] = m.limit
		push(m, {kind = .Limit, a = m.limit})
		pc^ += 1
	case .Limit_Cut:
		m.limit = slots[ins.a]
		pc^ += 1
	case .Limit_Restore, .Limit_Clear:
		push(m, {kind = .Limit, a = m.limit})
		m.limit = max(slots[ins.a], pos) if ins.op == .Limit_Restore else len(m.s)
		pc^ += 1
	}
	return true
}

// Returns the latest `open` entry of group `g` (0 for a call) that no `close` entry has closed. Each `close` skips the
// `open` it closes.
@(private = "file")
latest_open :: proc(stack: []Entry, open, close: Entry_Kind, g: int) -> Entry {
	level := 0
	#reverse for e in stack {
		if e.a != g {
			continue
		}
		if e.kind == close {
			level += 1
		} else if e.kind == open {
			if level == 0 {
				return e
			}
			level -= 1
		}
	}
	unreachable()
}

// Undoes entry `e`, which is not an alternative or a barrier, as the match backs past it.
@(private = "file")
undo :: #force_inline proc(m: ^Matcher, e: Entry, $EXT: bool) {
	#partial switch e.kind {
	case .Restore:
		m.slots[e.a] = e.b
	case .Retract:
		retract(m, e.a)
	}
	when EXT {
		#partial switch e.kind {
		case .Limit:
			m.limit = e.a
		case .Call_Frame:
			m.depth -= 1
		case .Return:
			m.depth += 1
		}
	}
}

// Resumes at the latest alternative, undoing the captures made since. Returns false when none is left.
@(private = "file")
backtrack :: proc(m: ^Matcher, pc, pos: ^int, $EXT, $SET: bool) -> bool {
	for len(m.stack) > 0 {
		e := pop(m.stack)
		#partial switch e.kind {
		case .Barrier:
			when SET {
				resize(m.log, int(e.b))
				m.looking -= 1
			}
			look := m.re.insts[e.pc]
			if k := Look_Kind(look.a); k == .Not_Ahead || k == .Not_Behind {
				pc^, pos^ = int(look.b) + 1, e.a
				return true
			}
			continue
		case .Branch:
			when SET {
				resize(m.log, int(e.b))
			}
			pc^, pos^ = int(e.pc), e.a
		case .Give_Back:
			// Every other entry was pushed at a pair's first visit, so only a bounded repeat's stops, given back or
			// taken lazily, can outnumber the pairs and spend the budget.
			when SET {
				if m.retries >= m.budget {
					m.err = BUDGET_OUT
					return false
				}
			}
			// Gives back a character, but a repeat that began inside a character stepped a byte at a time until the
			// next character began, as Oniguruma steps.
			p := e.a - 1
			q := p
			for q > e.b && m.s[q] & 0xC0 == 0x80 {
				q -= 1
			}
			if q > e.b || m.s[q] & 0xC0 != 0x80 {
				p = q
			}
			if p > e.b {
				push(m, {kind = .Give_Back, pc = e.pc, a = p, b = e.b})
			}
			pc^, pos^ = int(e.pc) + 2, p
		case .Take_More:
			when SET {
				if m.retries >= m.budget {
					m.err = BUDGET_OUT
					return false
				}
			}
			rep := m.re.insts[e.pc]
			next := step(m.re, m.re.insts[e.pc + 1], m.s[:m.limit], e.a)
			if next < 0 {
				continue
			}
			when SET {
				if rep.b < 0 && !first_visit(m, row_of(m, int(e.pc) + 1, next), next) { // as a greedy repeat marks its stops
					continue
				}
			}
			if rep.b < 0 || e.b + 1 < int(rep.b) {
				push(m, {kind = .Take_More, pc = e.pc, a = next, b = e.b + 1})
			}
			pc^, pos^ = int(e.pc) + 2, next
		case:
			undo(m, e, EXT)
			continue
		}
		m.retries += 1
		when !SET {
			if m.retries > m.cap {
				m.err = STEPS_OUT
				return false
			}
		}
		return true
	}
	return false
}

@(private)
assert_at :: proc(m: ^Matcher, kind: Assert_Kind, pos: int) -> bool {
	s := m.s
	switch kind {
	case .Begin_Buf:
		return pos == 0
	case .End_Buf:
		return pos == len(s)
	case .Semi_End_Buf:
		return pos == len(s) || (pos == len(s) - 1 && s[pos] == '\n')
	case .Begin_Line:
		return pos == 0 || (s[pos - 1] == '\n' && pos < len(s))
	case .End_Line:
		return pos == len(s) || s[pos] == '\n'
	case .Word_Boundary, .Not_Word_Boundary:
		before, after := false, false
		if pos > 0 { 	// the character before, whole even when `pos` is inside it, as Oniguruma finds it
			r := rune(s[pos - 1])
			if r >= 0x80 {
				r, _ = decode(s, char_start(s, pos - 1))
			}
			before = is_word(r)
		}
		// At position 0 Oniguruma reads the character after it only short of an absent operator's limit
		// (DATA_ENSURE), and at other positions up to the text's end.
		if pos < (m.limit if pos == 0 else len(s)) {
			r, _ := decode(s, pos)
			after = is_word(r)
		}
		return (before != after) == (kind == .Word_Boundary)
	case .Ascii_Boundary, .Not_Ascii_Boundary:
		before := pos > 0 && s[pos - 1] < 0x80 && is_word(rune(s[pos - 1]))
		after := pos < len(s) && s[pos] < 0x80 && is_word(rune(s[pos]))
		return (before != after) == (kind == .Ascii_Boundary)
	case .Search_Start:
		return pos == m.start
	case .Skip:
		return true
	case .Fail, .Mismatch, .Error, .Count, .Total_Count, .Max, .Cmp:
	}
	return false
}

// Returns the position after the text of the latest of the backreference's groups that matches at `pos`, or -1. Under
// ECMA a group that has not matched matches the empty string, and in a look-behind the text is read leftwards, ending
// at `pos`.
@(private = "file")
backref :: proc(m: ^Matcher, ins: Inst, pos: int) -> int {
	s := m.s[:m.limit] // the group's text may lie past the limit, but the match reads only up to it
	groups := m.re.refs[ins.a]
	#reverse for g in groups {
		lo, hi := m.slots[2 * g], m.slots[2 * g + 1]
		if lo < 0 || hi < 0 {
			if m.re.ecma {
				return pos
			}
			continue
		}
		text := m.s[lo:hi]
		if ins.b == 0 {
			if strings.has_prefix(s[pos:], text) {
				return pos + len(text)
			}
			continue
		}
		if m.re.ecma {
			return pos - len(text) if strings.has_suffix(s[:pos], text) else -1
		}
		p := pos
		matched := true
		for want in text {
			if p >= len(s) {
				matched = false
				break
			}
			r, w := decode(s, p)
			if fold(r) != fold(want) {
				matched = false
				break
			}
			p += w
		}
		if matched {
			return p
		}
	}
	return -1
}

// \R: "\r\n", or one of "\n" "\v" "\f" "\r" U+0085 U+2028 U+2029.
@(private = "file")
linebreak :: proc(s: string, pos: int) -> int {
	if pos >= len(s) {
		return -1
	}
	if strings.has_prefix(s[pos:], "\r\n") {
		return pos + 2
	}
	if s[pos] & 0xC0 == 0x80 {
		return -1 // inside a character: U+0085 is not its trailing byte
	}
	r, w := decode(s, pos)
	switch r {
	case '\n', '\v', '\f', '\r', 0x85, 0x2028, 0x2029:
		return pos + w
	}
	return -1
}
