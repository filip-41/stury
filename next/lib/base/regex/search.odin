package regex

// The search entry point. `search` asks the automata of dfa.odin and counting.odin first where they can answer, then
// runs the matcher of match.odin from each start the program can match at. After ten million backtracks at one start
// the matcher gives up with an error (ONIG_DEFAULT_RETRY_LIMIT_IN_MATCH) unless the caller gave `steps`.

import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/base/spell"

@(private = "file")
MAX_RETRIES :: 10_000_000 // ONIG_DEFAULT_RETRY_LIMIT_IN_MATCH
@(private = "file")
KEEP_BYTES :: 1 << 20 // scratch grown past this is freed after the search rather than kept

// What a `Scratch` keeps between searches.
@(private = "file")
Held :: struct {
	gate:   ^Gate,
	stack:  [dynamic]Entry,
	slots:  [dynamic]int,
	counts: [dynamic]int,
	// a linear search's visited pairs, one bit per instruction and position, or the counting search's sets
	seen:   [dynamic]u64,
	good:   [dynamic]u64, // the pairs inside a look-ahead whose body is known to match from there
	log:    [dynamic]u32, // the pairs first visited on the way through the look-aheads being matched
	// under counter loops, the visited set's rows and then each loop's counts, or the counting search's layout
	rows:   [dynamic]int,
}

// The matcher's stack and slots. A caller keeps one for its next search, and two searches running at once must not
// share one. `scratch_make` makes it and `scratch_destroy` frees it, and a zero `Scratch` is no scratch: `search`
// refuses it.
Scratch :: struct {
	spent: u64, // the steps the last search took, as `steps` counts them
	held:  Held,
}

// A scratch that allocates from `allocator`. `err` is `.Memory` when it cannot.
scratch_make :: proc(allocator: mem.Allocator) -> (scratch: Scratch, err: Error) {
	gate, allocated := new(Gate, allocator)
	if allocated != nil {
		return {}, MEMORY_OUT
	}
	gate.inner = allocator
	return {held = {gate = gate}}, {}
}

scratch_destroy :: proc(scratch: ^Scratch) {
	gate := scratch.held.gate
	if gate == nil {
		return
	}
	context.allocator = gate_allocator(gate)
	h := &scratch.held
	delete(h.stack)
	delete(h.slots)
	delete(h.counts)
	delete(h.seen)
	delete(h.good)
	delete(h.log)
	delete(h.rows)
	free(gate, gate.inner)
	scratch^ = {}
}

@(private)
Matcher :: struct {
	re:          ^Regex,
	s:           string,
	start:       int, // where the search began, for \G
	slots:       []int,
	stack:       ^[dynamic]Entry,
	retries:     int, // the alternatives resumed, at this start, or in all under `Regex.linear`
	retry_cap:   int, // the most retries the run at this start may take
	earlier:     u64, // the retries of the runs before this start
	allowed:     int, // under `limited`, the retries the runs may take in all
	err:         Error,
	caps:        []int,
	best_len:    int, // under `longest`, the longest match so far
	keep:        int, // under `longest`, where the last match at this start kept from (\K)
	skip:        int, // the furthest position a (*SKIP) reached, before which the next start may not be
	counts:      []int, // each callout's count (`Callout`)
	limit:       int, // the end of the text the match reads to, short of its end within an absent operator
	depth:       int, // calls not returned from
	behind:      Grapheme_Behind,
	seen, good:  []u64, // under `Regex.linear`, good only for a program with a look-ahead
	rows:        []int, // under `Regex.linear`, each instruction's first row of the visited set, nil when each has one
	radix:       []int, // under counter loops, the counts each loop's count is held to
	budget:      int, // under `Regex.linear`, the alternatives the search may resume
	log:         ^[dynamic]u32,
	looking:     int, // the look-aheads being matched, under `Regex.linear`
	room:        int, // under `Regex.linear`, the bytes the stack and the log may take beside the sets
	// Under `Regex.linear`, the sets hold the places from `lo` on, `width` places a row. `first_start` and `last_start`
	// are the first and last start a match can have.
	lo, width, first_start, last_start: int,
	limited:     bool, // the caller gave `steps`
}

// Finds the first match of `re` in `s` at or after byte `start`. `caps` receives the groups' byte bounds, 2 per group
// with the whole match first, -1 for a group that did not take part, and holds at most the program's groups. With no
// `caps` it only reports whether there is a match. `err` says why the search gave up, with Oniguruma's message.
//
// `steps` is the most work the search may do, counted in backtracks and in the set words of the counting automaton, and
// `err.kind` is `.Steps` when it runs out, with the match undecided. A search that the automaton of dfa.odin answers
// alone takes no steps. With `steps` 0 the search keeps to the engine's own limits instead: Oniguruma's retry limit at
// each start, and the limits that `SEARCH_RESUMES` and `COUNTING_WORK` give. A caller with a `tape.Budget` refuses a
// spent budget itself, as 0 here is not a spent one, and passes what is left. The memory limits are fixed.
// `scratch.spent` is what the search took, for the caller to charge.
search :: proc(
	re: ^Regex,
	s: string,
	start: int,
	caps: []int,
	scratch: ^Scratch,
	steps: u64 = 0,
) -> (found: bool, err: Error) {
	ensure(scratch.held.gate != nil, "regex.search needs a Scratch from scratch_make")
	ensure(start >= 0, "regex.search: start must not be negative")
	ensure(
		len(caps) == 0 || 2 <= len(caps) && len(caps) <= 2 * len(re.names) && len(caps) & 1 == 0,
		"regex.search: caps hold 2 ints for at most each group",
	)
	scratch.spent = 0
	if len(caps) == 0 && re.dfa != nil && re.ecma {
		if hit, judged := dfa_search(re.dfa, s, start); judged {
			return hit, {}
		}
	}
	return search_slow(re, s, start, caps, scratch, int(min(steps, u64(max(int)))))
}

@(private = "file")
search_slow :: #force_no_inline proc(
	re: ^Regex,
	s: string,
	start: int,
	caps: []int,
	scratch: ^Scratch,
	steps: int,
) -> (found: bool, err: Error) {
	limited := steps > 0
	jq_automaton, from, ok := automaton_start(re, s, start, steps if limited else MAX_RETRIES)
	if !ok {
		return false, {}
	}
	if len(caps) == 0 && jq_automaton && from >= 0 {
		if hit, judged := dfa_search(re.dfa, s, from); judged {
			return hit, {}
		}
	}
	// The automata give where the match ends and starts and how far a search reads. The backtracker then runs only at
	// that start, for the groups, and its visited set covers only that range.
	lo, width, first_start, last_start := 0, len(s) + 1, 0, len(s)
	if len(caps) > 0 && re.dfa != nil && re.dfa.first != nil && (jq_automaton || re.ecma) && from >= 0 {
		if end, reach, thread, judged := dfa_first(re.dfa, s, from); judged {
			if end < 0 {
				return false, {}
			}
			lo, width, last_start = from, reach - from + 1, end
			if begin, known := dfa_start(re.dfa, s, thread, end); known {
				if len(caps) == 2 {
					caps[0], caps[1] = begin, end
					return true, {}
				}
				lo, width, first_start, last_start = begin, reach - begin + 1, begin, begin
			}
		}
	}
	gate := scratch.held.gate
	gate.failed = false
	context.allocator = gate_allocator(gate)
	found, err = search_in(re, s, start, caps, scratch, steps, lo, width, first_start, last_start)
	if gate.failed {
		return false, MEMORY_OUT
	}
	return
}

@(private = "file")
search_in :: proc(
	re: ^Regex,
	s: string,
	start: int,
	caps: []int,
	scratch: ^Scratch,
	steps, lo, width, first_start, last_start: int,
) -> (found: bool, err: Error) {
	limited := steps > 0
	left := steps
	counted, decided, work := count_search(re, s, start, caps, scratch, false, left if limited else COUNTING_WORK)
	used := work
	scratch.spent = u64(used)
	if decided {
		return counted, {}
	}
	if limited {
		if left -= work; left <= 0 {
			return false, STEPS_OUT
		}
	}
	h := &scratch.held
	defer shrink(&h.stack)
	defer shrink(&h.rows)
	resize(&h.slots, re.slots)
	resize(&h.counts, len(re.callouts))
	if h.gate.failed {
		return false, {}
	}
	m := Matcher {
		re          = re,
		s           = s,
		start       = start,
		slots       = h.slots[:],
		counts      = h.counts[:],
		stack       = &h.stack,
		caps        = caps,
		best_len    = -1,
		limit       = len(s),
		lo          = lo,
		width       = width,
		first_start = first_start,
		last_start  = last_start,
		limited     = limited,
		allowed     = left,
		retry_cap   = left if limited else MAX_RETRIES,
	}
	slice.zero(m.counts)
	// The visited set is bounded by the text, so the memory cap replaces the retry limit and the jq stack cap. The set
	// persists across starts, so a search where a pair's outcome depends on the start (`longest`, `not_empty`) runs
	// without it, and so does a jq program whose set would pass the cap.
	linear := re.linear && !re.longest && !re.not_empty
	if linear {
		fallback, hit, done := setup_visited(&m, scratch, &used, left, limited)
		if done {
			return hit, fallback
		}
		linear = m.room >= 0
	}
	defer if linear {
		shrink(&h.seen)
		shrink(&h.good)
		shrink(&h.log)
	}
	switch {
	case re.calls_or_limits:
		found = try_starts(&m, true, false)
	case linear:
		found = try_starts(&m, false, true)
	case:
		found = try_starts(&m, false, false)
	}
	err = m.err
	scratch.spent = u64(used) + m.earlier + u64(m.retries)
	if !h.gate.failed && re.counting != nil && err.kind != .None && err.kind != .Callout {
		// What the counting search may still read is what the backtracker left of the limit, none of it when spent.
		remaining := left - int(m.earlier) - m.retries if limited else COUNTING_WORK
		if remaining > 0 {
			counted, decided, work = count_search(re, s, start, caps, scratch, true, remaining)
			used += work
			scratch.spent = u64(used) + m.earlier + u64(m.retries)
			if decided {
				return counted, {}
			}
			if limited && work >= remaining {
				return false, STEPS_OUT
			}
		}
	}
	return found, err
}

// Sizes and allocates the visited sets for a linear search, or resolves an oversized ECMA search through `count_search`.
@(private = "file")
setup_visited :: proc(
	m: ^Matcher,
	scratch: ^Scratch,
	used: ^int,
	left: int,
	limited: bool,
) -> (err: Error, hit, done: bool) {
	re, s, h := m.re, m.s, &scratch.held
	m.rows, m.radix = re.visited.rows, nil
	plain, most := total_rows(re, m.rows), MAX_BYTES
	if re.visited.counters != nil {
		m.rows, m.radix, plain = counted_rows(re, len(s) + 1, scratch)
		if h.gate.failed {
			return {}, false, true
		}
		most = COUNTED_BYTES
	}
	switch {
	case limited:
		m.budget = left
	case re.ecma:
		m.budget = max(SEARCH_RESUMES, sat_mul(sat_mul(SEARCH_WORK, plain), m.width))
	case:
		m.budget = max(int)
	}
	rows := total_rows(re, m.rows)
	words := set_words(rows, m.width)
	m.room = visited_room(re, rows, m.width, most)
	if m.room < 0 {
		if !re.ecma {
			return {}, false, false
		}
		counted, decided, work := count_search(re, s, m.start, m.caps, scratch, true, left if limited else COUNTING_WORK)
		used^ += work
		scratch.spent = u64(used^)
		if decided {
			return {}, counted, true
		}
		return STEPS_OUT if limited && work >= left else MEMORY_OUT, false, true
	}
	resize(&h.seen, words)
	slice.zero(h.seen[:])
	m.seen = h.seen[:]
	if re.visited.owner != nil {
		resize(&h.good, words)
		slice.zero(h.good[:])
		m.good = h.good[:]
	}
	clear(&h.log)
	m.log = &h.log
	if h.gate.failed {
		return {}, false, true
	}
	return {}, false, false
}

// Whether the automaton of dfa.odin may answer a jq search, and from where it reads. Oniguruma's search gives up past
// its retry limit where the automata would still answer, so under jq they answer only where the visited set runs the
// program, which never gives up, or where no start can take as many retries as `retries`. Under jq the automata start
// at Oniguruma's first start, which its optimizer can place past a match. The starts it skips after that cannot have a
// match, but when it searches windows of starts in turn (`high < last` in `try_starts`) the backtracker does the
// search. `ok` is false when no start can match.
@(private = "file")
automaton_start :: #force_inline proc(
	re: ^Regex,
	s: string,
	start: int,
	retries: int,
) -> (
	jq_automaton: bool,
	from: int,
	ok: bool,
) {
	jq_automaton = !re.ecma && re.dfa != nil && !re.longest && !re.not_empty && !re.calls_or_limits
	if jq_automaton {
		if re.linear {
			jq_automaton = visited_room(re, total_rows(re, re.visited.rows), len(s) + 1) >= 0
		} else {
			jq_automaton = retries_bounded(re.dfa, len(s) - min(start, len(s)), retries)
		}
	}
	from = start
	if jq_automaton && re.narrowed && start <= len(s) {
		first, last, _, high, found := search_starts(re.opt, s, start)
		if !found {
			return jq_automaton, from, false
		}
		from = first if high >= last else -1
	}
	return jq_automaton, from, true
}

// The counting search's answer to a search of an ECMA program with counted repeats that reads no bounds: `after`
// false for a program with counter loops, before the backtracker, and true for one without, once the backtracker gave
// up. `judged` is false when it does not run or does not decide. `work` is the set words it read, which it holds to
// `limit`, above 0.
@(private = "file")
count_search :: #force_inline proc(
	re: ^Regex,
	s: string,
	start: int,
	caps: []int,
	scratch: ^Scratch,
	after: bool,
	limit: int,
) -> (found, judged: bool, work: int) {
	if len(caps) > 0 || re.counting == nil || re.counting.loops == after {
		return
	}
	found, judged, work = counting_search(re, s, start, scratch, limit)
	shrink(&scratch.held.seen)
	shrink(&scratch.held.rows)
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

// The next byte at or after `at` where a match of head `h` can start, or -1 for none.
@(private)
skip_head :: #force_inline proc(h: ^Search_Opt, s: string, at: int) -> int {
	if h.kind == .Exact {
		k := strings.index(s[at:], h.exact)
		return at + k if k >= 0 else -1
	}
	return next_head_byte(h, s, at) if h.kind == .Map else at
}

@(private = "file")
try_starts :: proc(m: ^Matcher, $EXT, $SET: bool) -> bool {
	re, s, start := m.re, m.s, m.start
	first, last, limit, high := start, len(s), len(s), INFINITE_LEN
	if re.narrowed {
		ok: bool
		if first, last, limit, high, ok = search_starts(re.opt, s, start); !ok {
			return false
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
			if at = skip_head(re.head, s, at); at < 0 {
				break starts
			}
			if at > end {
				break
			}
			if run(m, at, EXT, SET) {
				return true
			}
			if m.err.kind != .None {
				return false
			}
			if at >= len(s) {
				break starts
			}
			at = max(at + spell.lead_width(s[at]), m.skip)
		}
		if !windowed {
			break
		}
	}
	return m.best_len >= 0
}
