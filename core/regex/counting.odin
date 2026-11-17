#+private
package regex

// The search that decides an ECMA program with counted repeats in one pass over the text, for a caller that reads no
// bounds. It follows every thread at once, as an automaton does, and keeps for each instruction the set of counts of
// the repeats around it, as in Turoňová et al., "Regex Matching with Counting-Set Automata" (OOPSLA 2020).
//
// A thread at an instruction is its counts of the repeats around it. Past a repeat's least count, a smaller count
// leaves open every way on that a larger one does, so of the counts from the least on, with the counts of the repeats
// around equal, only the smallest is kept. An instruction's set has a bit for each count of each repeat around it
// short of the innermost one, times the innermost one's least count plus one, the last bit standing for the counts
// from the least on, whose smallest is kept beside it. A count that the text is too short to pass is not kept, so a
// repeat around another holds min(most, least + the text's length) + 1 counts and a repeated character min(most, the
// text's length) + 1, where `{n,}` holds n + 1.
//
// It decides the program's language, as the automata do (dfa.odin): an iteration that matches empty past a repeat's
// least count is followed here though ECMA fails it, since the count it reaches is one a thread with an iteration
// fewer has at the same place.

import "base:intrinsics"
import "core:slice"
import "core:strings"

// The repeats of an ECMA program that `counting_search` follows, kept behind a pointer since a Regex is copied.
Counting :: struct {
	repeats: []Counted,
	of:      []i32, // the innermost repeat each instruction lies in, -1 for none
	reach:   int, // the most bytes one reading instruction steps over
	loops:   bool, // the program has counter loops, whose budget the backtracker would spend
}

// A counter loop, from its Count to its Count_Next, or a Rep's character, with its least and most counts (-1: no
// bound) and the repeat around it, -1 for none.
Counted :: struct {
	least, most, outer: int,
	rep:                bool,
}

// The repeats of `insts` for `counting_search`, or nil when the program has an instruction the search does not follow,
// a look-around or a back reference among them.
counting_of :: proc(insts: []Inst) -> ^Counting {
	reach := 4
	for ins in insts {
		#partial switch ins.op {
		case .Str:
			reach = max(reach, int(ins.b))
		case .Assert:
			if Assert_Kind(ins.a) >= .Fail {
				return nil
			}
		case .Match, .Char_Fold, .Any, .Any_All, .Class, .Split, .Split_Head, .Jmp, .Save, .Set, .Check, .Unset, .Rep, .Rep_Lazy, .Count_Reset, .Count, .Count_Lazy, .Count_Next, .Count_Check:
		case:
			return nil
		}
	}
	c := new(Counting)
	c.reach = reach
	c.of = make([]i32, len(insts))
	slice.fill(c.of, -1)
	repeats := make([dynamic]Counted)
	for ins, pc in insts {
		#partial switch ins.op {
		case .Count_Reset:
			c.loops = true
			loop, bounds := insts[pc + 1], insts[pc + 2]
			append(&repeats, Counted{int(bounds.a), int(bounds.b), int(c.of[pc]), false})
			slice.fill(c.of[pc + 1:int(loop.b)], i32(len(repeats) - 1))
		case .Rep, .Rep_Lazy:
			append(&repeats, Counted{int(ins.a), int(ins.b), int(c.of[pc]), true})
			c.of[pc + 1] = i32(len(repeats) - 1)
		}
	}
	c.repeats = repeats[:]
	return c
}

// Each instruction's threads at one place, or those arriving at a place ahead: a bit for each, and for each count of
// the repeats around the innermost one, the smallest of its counts from its least on.
@(private = "file")
Sets :: struct {
	bits:  []u64,
	least: []int,
}

// The threads of a search: those at the place being read (`cur`), with what of them is still to be followed (`delta`),
// and those arriving at the next `ring` places, in a ring indexed by the place. Each list holds an instruction at most
// once, which its bit in the bit set beside it tells.
@(private = "file")
Threads :: struct {
	re:               ^Regex,
	radix, slots:     []int, // each repeat's counts kept as a repeat around another, and as the innermost one
	words, blocks:    []int, // each instruction's first word of `bits` and first entry of `least`, the totals last
	cur:              Sets,
	delta, tmp:       []u64,
	live_set, queued: []u64,
	live, stack:      []int,
	lived, stacked:   int,
	ring:             Sets, // a slot's sets after another's
	touched:          []u64, // per slot of the ring, the instructions arriving there
	arrivals:         []int,
	arrived:          []int, // per slot, the number of its arrivals
	arriving:         int, // the arrivals in all slots
	work:             int,
}

// The set words a search may read, past which it gives the search back to the backtracker.
@(private = "file")
COUNTING_WORK :: 1 << 28

// Whether `re`'s program matches in `s` at or after byte `start`, its starts those `search` tries. `judged` is false
// when the sets the text allows would pass COUNTED_BYTES, or the search would pass COUNTING_WORK.
counting_search :: proc(re: ^Regex, s: string, start: int, scratch: ^Scratch) -> (found, judged: bool) {
	st := Starts{at = start, last = len(s), limit = len(s), high = INFINITE_LEN}
	if re.narrowed {
		ok: bool
		if st.at, st.last, st.limit, st.high, ok = search_starts(re.opt, s, start); !ok {
			return false, true
		}
	}
	st.windowed = st.high < st.last
	st.end = st.at - 1 if st.windowed else st.last
	c := re.counting
	n, k, ring := len(re.insts), len(c.repeats), c.reach + 1
	text := max(len(s) - start, 0)
	flags := (n + 63) / 64
	resize(&scratch.rows, 3 * k + 2 * (n + 1) + 2 * n + ring * n + ring)
	rows := scratch.rows[:]
	t := Threads{re = re}
	cells: []int // the counts of a repeat and those around it, each kept whole
	t.radix, rows = rows[:k], rows[k:]
	t.slots, rows = rows[:k], rows[k:]
	cells, rows = rows[:k], rows[k:]
	t.words, rows = rows[:n + 1], rows[n + 1:]
	t.blocks, rows = rows[:n + 1], rows[n + 1:]
	t.live, rows = rows[:n], rows[n:]
	t.stack, rows = rows[:n], rows[n:]
	t.arrivals, t.arrived = rows[:ring * n], rows[ring * n:]
	most_cells := COUNTED_BYTES * 8 + 1
	for r, i in c.repeats {
		bound := r.most if r.most >= 0 else r.least
		t.radix[i] = min(bound, text + (0 if r.rep else r.least)) + 1
		t.slots[i] = min(r.least, t.radix[i] - 1) + 1
		cells[i] = min(t.radix[i] * (cells[r.outer] if r.outer >= 0 else 1), most_cells)
	}
	t.words[0], t.blocks[0] = 0, 0
	widest := 1
	for pc in 0 ..< n {
		blocks, width := 1, 1
		if k := c.of[pc]; k >= 0 {
			outer := c.repeats[k].outer
			blocks = cells[outer] if outer >= 0 else 1
			width = min(blocks * t.slots[k], most_cells)
		}
		widest = max(widest, (width + 63) / 64)
		t.words[pc + 1] = min(t.words[pc] + (width + 63) / 64, most_cells)
		t.blocks[pc + 1] = min(t.blocks[pc] + blocks, most_cells)
	}
	words, blocks := t.words[n], t.blocks[n]
	if ((2 + ring) * words + widest + (2 + ring) * flags + (1 + ring) * blocks) * size_of(u64) > COUNTED_BYTES {
		return false, false
	}
	resize(&scratch.seen, (2 + ring) * words + widest + (2 + ring) * flags + (1 + ring) * blocks)
	sets := scratch.seen[:]
	slice.zero(sets)
	slice.zero(t.arrived)
	take :: proc(sets: ^[]u64, n: int) -> []u64 {
		part := sets[:n]
		sets^ = sets[n:]
		return part
	}
	t.cur = {take(&sets, words), slice.reinterpret([]int, take(&sets, blocks))}
	t.delta, t.tmp = take(&sets, words), take(&sets, widest)
	t.live_set, t.queued = take(&sets, flags), take(&sets, flags)
	t.touched = take(&sets, ring * flags)
	t.ring = {take(&sets, ring * words), slice.reinterpret([]int, take(&sets, ring * blocks))}

	m := Matcher{re = re, s = s, start = start, limit = len(s)}
	next := next_start(&st, re, s)
	for p := next; p <= len(s); p += 1 {
		if t.arriving == 0 && p < next {
			if next > len(s) {
				break
			}
			p = next // no thread is under way before the next start
		}
		slot := p % ring
		if t.arrived[slot] == 0 && p != next {
			continue
		}
		arrive := ring_slot(&t, slot)
		for pc in t.arrivals[slot * n:][:t.arrived[slot]] {
			bits := arrive.bits[t.words[pc]:t.words[pc + 1]]
			for w, i in bits {
				for x := w; x != 0; x &= x - 1 {
					o, count := thread(&t, arrive, pc, i * 64 + int(intrinsics.count_trailing_zeros(x)))
					add(&t, pc, o, count)
				}
			}
			slice.zero(bits)
			t.touched[slot * flags + (pc >> 6)] &~= 1 << (u64(pc) & 63)
		}
		t.arriving -= t.arrived[slot]
		t.arrived[slot] = 0
		if p == next {
			add(&t, 0, 0, 0)
			next = next_start(&st, re, s)
		}
		if close_threads(&t, &m, p) {
			return true, true
		}
		read_threads(&t, s, p)
		for pc in t.live[:t.lived] {
			slice.zero(t.cur.bits[t.words[pc]:t.words[pc + 1]])
			t.live_set[pc >> 6] &~= 1 << (u64(pc) & 63)
		}
		t.lived = 0
		if t.work > COUNTING_WORK {
			return false, false
		}
	}
	return false, true
}

// Follows the threads at `pos` through the instructions that read nothing, true once one reaches Match.
@(private = "file")
close_threads :: proc(t: ^Threads, m: ^Matcher, pos: int) -> bool {
	re := t.re
	for t.stacked > 0 {
		t.stacked -= 1
		pc := t.stack[t.stacked]
		t.queued[pc >> 6] &~= 1 << (u64(pc) & 63)
		ins := re.insts[pc]
		if ins.op == .Match {
			return true
		}
		delta := t.delta[t.words[pc]:t.words[pc + 1]]
		bits := t.tmp[:len(delta)]
		copy(bits, delta)
		slice.zero(delta)
		t.work += len(bits)
		for w, i in bits {
			for x := w; x != 0; x &= x - 1 {
				o, count := thread(t, t.cur, pc, i * 64 + int(intrinsics.count_trailing_zeros(x)))
				follow(t, m, pc, ins, pos, o, count)
			}
		}
	}
	return false
}

// Moves the thread at `pc` of counts `o` of the repeats around the innermost one and `count` of that one on through an
// instruction that reads nothing.
@(private = "file")
follow :: proc(t: ^Threads, m: ^Matcher, pc: int, ins: Inst, pos, o, count: int) {
	c := t.re.counting
	#partial switch ins.op {
	case .Split:
		add(t, int(ins.a), o, count)
		add(t, int(ins.b), o, count)
	case .Split_Head:
		add(t, pc + 1, o, count)
		add(t, int(ins.b), o, count)
	case .Jmp:
		add(t, int(ins.a), o, count)
	case .Save, .Set, .Unset, .Check, .Count_Check:
		add(t, pc + 1, o, count)
	case .Assert:
		if assert_at(m, Assert_Kind(ins.a), pos) {
			add(t, pc + 1, o, count)
		}
	case .Rep, .Rep_Lazy, .Count_Reset:
		if k := c.of[pc]; k >= 0 {
			add(t, pc + 1, o * t.radix[k] + count, 0)
		} else {
			add(t, pc + 1, 0, 0)
		}
	case .Count, .Count_Lazy:
		r := c.repeats[c.of[pc]]
		if count < r.most {
			add(t, pc + 2, o, count)
		}
		if count >= r.least {
			leave(t, int(ins.b), r.outer, o)
		}
	case .Count_Next:
		if count + 1 < t.radix[c.of[pc]] {
			add(t, int(ins.b), o, count + 1)
		}
	case .Str, .Char_Fold, .Any, .Any_All, .Class:
		if is_repeated(t.re.insts, pc) {
			if r := c.repeats[c.of[pc]]; count >= r.least {
				leave(t, pc + 1, r.outer, o)
			}
		}
	}
}

// Adds the thread of counts `o` of the repeats around a repeat that it leaves, whose outer repeat is `outer`, at `pc`.
@(private = "file")
leave :: #force_inline proc(t: ^Threads, pc, outer, o: int) {
	if outer < 0 {
		add(t, pc, 0, 0)
	} else {
		add(t, pc, o / t.radix[outer], o % t.radix[outer])
	}
}

// The threads at `pos` that read a character send what they become to the place after it.
@(private = "file")
read_threads :: proc(t: ^Threads, s: string, pos: int) {
	re := t.re
	for pc in t.live[:t.lived] {
		ins := re.insts[pc]
		#partial switch ins.op {
		case .Str, .Char_Fold, .Any, .Any_All, .Class:
		case:
			continue
		}
		next := step(re, ins, s, pos)
		if next < 0 {
			continue
		}
		bits := t.cur.bits[t.words[pc]:t.words[pc + 1]]
		t.work += len(bits)
		repeated := is_repeated(re.insts, pc)
		to := pc if repeated else pc + 1
		for w, i in bits {
			for x := w; x != 0; x &= x - 1 {
				o, count := thread(t, t.cur, pc, i * 64 + int(intrinsics.count_trailing_zeros(x)))
				if !repeated {
					arrive(t, next, to, o, count)
				} else if count + 1 < t.radix[re.counting.of[pc]] {
					arrive(t, next, to, o, count + 1) // a repeated character counts one more
				} else if re.insts[pc - 1].b < 0 {
					arrive(t, next, to, o, count) // `{n,}` holds its count at n
				}
			}
		}
	}
}

// Whether the reading instruction at `pc` is a Rep's character.
@(private = "file")
is_repeated :: #force_inline proc(insts: []Inst, pc: int) -> bool {
	return pc > 0 && (insts[pc - 1].op == .Rep || insts[pc - 1].op == .Rep_Lazy)
}

// The thread of bit `bit` of `pc`'s set in `sets`: its counts `o` of the repeats around the innermost one, and `count`
// of that one.
@(private = "file")
thread :: #force_inline proc(t: ^Threads, sets: Sets, pc, bit: int) -> (o, count: int) {
	k := t.re.counting.of[pc]
	if k < 0 {
		return 0, 0
	}
	slots := t.slots[k]
	o, count = bit / slots, bit % slots
	if count == slots - 1 {
		count = sets.least[t.blocks[pc] + o]
	}
	return
}

// Puts the thread of counts `o` and `count` at `pc` in `sets`. Returns its bit, or -1 when `sets` already had it or
// one with a smaller count from the least on.
@(private = "file")
put :: #force_inline proc(t: ^Threads, sets: Sets, pc, o, count: int) -> int {
	bit := 0
	if k := t.re.counting.of[pc]; k >= 0 {
		slots := t.slots[k]
		bit = o * slots + min(count, slots - 1)
		if count >= slots - 1 {
			least := &sets.least[t.blocks[pc] + o]
			had := has_bit(sets.bits, t.words[pc] * 64 + bit)
			if had && count >= least^ {
				return -1
			}
			least^ = count
			if had {
				return bit
			}
		}
	}
	at := t.words[pc] * 64 + bit
	if has_bit(sets.bits, at) {
		return -1
	}
	add_bit(sets.bits, at)
	return bit
}

// Adds the thread of counts `o` and `count` at `pc` to the place being read, to be followed when it is new.
@(private = "file")
add :: proc(t: ^Threads, pc, o, count: int) {
	bit := put(t, t.cur, pc, o, count)
	if bit < 0 {
		return
	}
	add_bit(t.delta, t.words[pc] * 64 + bit)
	if !has_bit(t.live_set, pc) {
		add_bit(t.live_set, pc)
		t.live[t.lived] = pc
		t.lived += 1
	}
	if !has_bit(t.queued, pc) {
		add_bit(t.queued, pc)
		t.stack[t.stacked] = pc
		t.stacked += 1
	}
}

// Adds the thread of counts `o` and `count` at `pc` to those arriving at byte `at`, listing `pc` there.
@(private = "file")
arrive :: proc(t: ^Threads, at, pc, o, count: int) {
	n := len(t.live)
	slot := at % (len(t.arrived))
	put(t, ring_slot(t, slot), pc, o, count)
	touched := t.touched[slot * ((n + 63) / 64):]
	if !has_bit(touched, pc) {
		add_bit(touched, pc)
		t.arrivals[slot * n + t.arrived[slot]] = pc
		t.arrived[slot] += 1
		t.arriving += 1
	}
}

// The sets arriving at the ring's `slot`.
@(private = "file")
ring_slot :: #force_inline proc(t: ^Threads, slot: int) -> Sets {
	words, blocks := t.words[len(t.live)], t.blocks[len(t.live)]
	return {t.ring.bits[slot * words:][:words], t.ring.least[slot * blocks:][:blocks]}
}

// The starts `search` tries from `at`, up to `end` in the window of starts it is in, up to `last` in all.
@(private = "file")
Starts :: struct {
	at, end, last, limit, high: int,
	windowed:                   bool,
}

// The next start of `st`, as `try_starts` takes them, past the text's end for none.
@(private = "file")
next_start :: proc(st: ^Starts, re: ^Regex, s: string) -> int {
	for st.at <= st.last {
		if st.at > st.end {
			if !st.windowed {
				break
			}
			if st.at = next_window(re.opt, s, st.at, st.limit, &st.high); st.at < 0 {
				break
			}
			st.end = min(st.high, st.last)
		}
		at := st.at
		#partial switch h := re.head; h.kind {
		case .Exact:
			k := strings.index(s[at:], h.exact)
			if k < 0 {
				return len(s) + 1
			}
			at += k
		case .Map:
			for at < len(s) && !has_bit(h.set[:], int(s[at])) {
				at += lead_width(s[at])
			}
			if at >= len(s) {
				return len(s) + 1
			}
		}
		st.at = at
		if at <= st.end {
			st.at = at + lead_width(s[at]) if at < len(s) else st.last + 1
			return at
		}
	}
	st.at = st.last + 1
	return len(s) + 1
}
