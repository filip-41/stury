package regex

// The backtracking matcher, which tries a program's alternatives in order as Oniguruma does, so a match
// and its captures are the ones Oniguruma finds. It gives up as Oniguruma does after ten million
// backtracks at one start (ONIG_DEFAULT_RETRY_LIMIT_IN_MATCH), and its stack is capped where Oniguruma's
// would grow without bound.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

MAX_RETRIES :: 10_000_000 // ONIG_DEFAULT_RETRY_LIMIT_IN_MATCH; past it the match errors, as Oniguruma's does
MAX_STACK :: 1 << 23 // entries, 24 bytes each
KEEP_STACK :: 1 << 16 // entries: a backtrack stack grown past this is freed after the search rather than kept
MAX_CALL_NEST :: 20 // Oniguruma's subexp_call_nest_counter limit as jq builds it, a group in place counted

@(private = "file")
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

// What a look's or atomic group's end keeps of its body: all but the alternatives.
@(private = "file")
KEPT :: bit_set[Entry_Kind]{.Restore, .Retract, .Call_Frame, .Return, .Mem_Start, .Mem_End, .Limit}

@(private = "file")
Entry :: struct {
	kind: Entry_Kind,
	pc:   i32,
	a, b: int,
}

// The matcher's stack and slots, kept for the thread's next search. A search finishes before the caller
// runs anything that could search again.
@(private = "file", thread_local)
scratch: struct {
	stack:  [dynamic]Entry,
	slots:  [dynamic]int,
	counts: [dynamic]int,
}

@(private = "file")
Matcher :: struct {
	re:       ^Regex,
	s:        string,
	start:    int, // where the search began, for \G
	slots:    []int,
	stack:    ^[dynamic]Entry,
	retries:  int,
	err:      string,
	caps:     []int,
	best_len: int, // under `longest`, the longest match so far
	keep:     int, // under `longest`, where the last match at this start kept from (\K)
	skip:     int, // the furthest a (*SKIP) was reached, where the next start may not be before
	counts:   []int, // each callout's count (`Callout`)
	limit:    int, // the end of the text the match reads to, short of its end within an absent operator
	depth:    int, // calls not returned from
	behind:   Grapheme_Behind,
}

// The first match of `re` in `s` at or after byte `start`, with its groups' byte bounds in `caps` (2 per group with
// the whole match; -1 for a group that did not take part), or Oniguruma's message when the search gave up.
search :: proc(re: ^Regex, s: string, start: int, caps: []int) -> (found: bool, err: string) {
	if scratch.stack == nil {
		scratch.stack = make([dynamic]Entry, 0, 64, runtime.heap_allocator())
	}
	if scratch.slots == nil {
		scratch.slots = make([dynamic]int, 0, 16, runtime.heap_allocator())
		scratch.counts = make([dynamic]int, 0, 4, runtime.heap_allocator())
	}
	defer if cap(scratch.stack) > KEEP_STACK { // a deep search's stack is not kept for the next
		delete(scratch.stack)
		scratch.stack = nil
	}
	resize(&scratch.slots, re.slots)
	resize(&scratch.counts, len(re.callouts))
	m := Matcher{re = re, s = s, start = start, slots = scratch.slots[:], counts = scratch.counts[:], stack = &scratch.stack, caps = caps, best_len = -1, limit = len(s)}
	for &n in m.counts {
		n = 0
	}
	if re.required != "" && strings.index(s[start:], re.required) < 0 {
		return false, ""
	}
	for at := start; at <= len(s); {
		if re.anchored && at != 0 {
			break
		}
		if re.prefix != "" {
			k := strings.index(s[at:], re.prefix)
			if k < 0 {
				break
			}
			at += k
		} else if re.has_first {
			for at < len(s) && re.first[s[at] >> 6] & (1 << (u64(s[at]) & 63)) == 0 {
				at += lead_width(s[at])
			}
			if at >= len(s) {
				break
			}
		}
		if re.calls_or_limits ? run(&m, at, true) : run(&m, at, false) {
			return true, ""
		}
		if m.err != "" {
			return false, m.err
		}
		if at >= len(s) {
			break
		}
		at = max(at + lead_width(s[at]), m.skip)
	}
	return m.best_len >= 0, ""
}

// Bytes Oniguruma steps over from `b` to the next place a search tries, which inside a character (where
// jq's global search can start one) is one byte.
@(private = "file")
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

// The character at `pos`, inside a character, where jq's global search can start. Oniguruma reads a byte as the code
// point of its value.
@(private)
decode :: #force_inline proc(s: string, pos: int) -> (rune, int) {
	if s[pos] < 0xC0 {
		return rune(s[pos]), 1
	}
	return utf8.decode_rune_in_string(s[pos:])
}

@(private)
char_start :: #force_inline proc(s: string, p: int) -> int {
	p := p
	for p > 0 && s[p] & 0xC0 == 0x80 {
		p -= 1
	}
	return p
}

@(private = "file")
class_match :: #force_inline proc(cls: ^Class, r: rune) -> bool {
	if r >= 0 && r < 0x80 {
		return cls.ascii[r >> 6] & (1 << (u64(r) & 63)) != 0
	}
	return class_match_slow(cls, r)
}

// The position after the one-rune instruction `in` matches at `pos`, or -1.
@(private = "file")
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

// Runs the program from `at`: true on a match (written to m.caps), false on none or on an error in m.err.
@(private = "file")
run :: proc(m: ^Matcher, at: int, $EXT: bool) -> bool {
	re, s := m.re, m.s
	insts := re.insts
	slots := m.slots
	for &x in slots {
		x = -1
	}
	slots[0] = at
	for c, i in re.callouts {
		if c.kind != .Total_Count {
			m.counts[i] = 0 // as Oniguruma clears a callout's data at each start, but TOTAL_COUNT's
		}
	}
	clear(m.stack)
	m.retries = 0
	when EXT {
		m.limit, m.depth = len(m.s), 0
	}
	pc, pos := 0, at
	m.keep = at
	for {
		ins := insts[pc]
		ok := true
		switch ins.op {
		case .Match:
			if re.not_empty && pos == at {
				ok = false
				break
			}
			// A \K in a look-ahead may keep past the end, where Oniguruma starts the match at its end.
			if !re.longest {
				copy(m.caps, slots[:len(m.caps)])
				m.caps[0], m.caps[1] = min(m.caps[0], pos), pos
				return true
			}
			// Oniguruma takes the latest \K on the stack, or where the last match at this start kept from when
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
				copy(m.caps, slots[:len(m.caps)])
				m.caps[0], m.caps[1] = min(m.keep, pos), pos
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
			if len(m.stack) >= MAX_STACK {
				m.err = "match-stack limit over"
				return false
			}
			push(m, {kind = .Branch, pc = ins.b, a = pos})
			pc = int(ins.a)
		case .Split_Head:
			if pos >= len(s) || s[pos] != byte(ins.a) {
				pc = int(ins.b)
				continue
			}
			if len(m.stack) >= MAX_STACK {
				m.err = "match-stack limit over"
				return false
			}
			push(m, {kind = .Branch, pc = ins.b, a = pos})
			pc += 1
		case .Jmp:
			pc = int(ins.a)
		case .Save:
			push(m, {kind = .Restore, a = int(ins.a), b = slots[ins.a]})
			slots[ins.a] = pos
			if ins.b != 0 {
				// Oniguruma pushes a referenced group's start (OP_MEM_START_PUSH), which unsets its end until
				// the group closes again: a backreference or condition inside sees it unset, never a start
				// past the last iteration's end.
				push(m, {kind = .Restore, a = int(ins.a) + 1, b = slots[ins.a + 1]})
				slots[ins.a + 1] = -1
			}
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
			push(m, {kind = .Barrier, pc = i32(pc), a = pos})
			pc += 1
		case .Look_End:
			k := len(m.stack) - 1
			for m.stack[k].kind != .Barrier {
				k -= 1
			}
			bar := m.stack[k]
			switch Look_Kind(insts[bar.pc].a) {
			case .Not_Ahead, .Not_Behind:
				// The body matched, so the assertion fails: undo the body and fail past it.
				for len(m.stack) > k {
					undo(m, pop(m.stack), EXT)
				}
				ok = false
			case .Ahead, .Behind, .Atomic:
				// The body's alternatives go, what it captured stays, and is undone when the match backs past it.
				w := k
				for j in k + 1 ..< len(m.stack) {
					if m.stack[j].kind in KEPT {
						m.stack[w] = m.stack[j]
						w += 1
					}
				}
				resize(m.stack, w)
				// A look-behind goes on where its body ends, as Oniguruma's of one length does not restore the
				// position: where it began, but past it when it began within a character.
				if Look_Kind(insts[bar.pc].a) == .Ahead {
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
			pc = int(ins.b) if slots[ins.a] == pos else pc + 1
		case .Cond:
			pc = pc + 1 if slots[2 * ins.a + 1] >= 0 else int(ins.b)
		case .Linebreak:
			next := linebreak(s, pos)
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
				for ins.b < 0 || count < int(ins.b) {
					next := step(re, one, s, p)
					if next < 0 {
						break
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
			if len(m.stack) >= MAX_STACK {
				m.err = "match-stack limit over"
				return false
			}
			if ins.op == .Count {
				push(m, {kind = .Branch, pc = ins.b, a = pos})
				pc += 2
			} else {
				push(m, {kind = .Branch, pc = i32(pc + 2), a = pos})
				pc = int(ins.b)
			}
		case .Count_Next:
			push(m, {kind = .Restore, a = int(ins.a), b = slots[ins.a]})
			slots[ins.a] += 1
			pc = int(ins.b)
		case .Call, .Return, .Mem_Start, .Mem_End, .Limit_Save, .Limit_Cut, .Limit_Restore, .Limit_Clear:
			when EXT {
				ok = call_or_limit(m, ins, &pc, pos)
				s = m.s[:m.limit]
			} else {
				unreachable()
			}
		}
		if !ok {
			if !backtrack(m, &pc, &pos, EXT) {
				return false
			}
			when EXT {
				s = m.s[:m.limit]
			}
		}
	}
}

// The ops of subexpression calls and the absent operator, kept out of `run`'s loop, which patterns without
// them run with none of their tracking (`Regex.calls_or_limits`).
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
		// The start of this group's own run, past the starts and ends of runs it called.
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

// The latest `open` entry of group `g` (0 for a call) not closed, a `close` passing over the one it closed.
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

// Resumes at the latest alternative, undoing the captures made since. It returns false when none is left.
@(private = "file")
backtrack :: proc(m: ^Matcher, pc, pos: ^int, $EXT: bool) -> bool {
	for len(m.stack) > 0 {
		e := pop(m.stack)
		#partial switch e.kind {
		case .Barrier:
			look := m.re.insts[e.pc]
			if k := Look_Kind(look.a); k == .Not_Ahead || k == .Not_Behind {
				pc^, pos^ = int(look.b) + 1, e.a
				return true
			}
			continue
		case .Branch:
			pc^, pos^ = int(e.pc), e.a
		case .Give_Back:
			// Back a character, but a repeat that began inside a character stepped a byte at a time until the next
			// one began, as Oniguruma steps.
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
			rep := m.re.insts[e.pc]
			next := step(m.re, m.re.insts[e.pc + 1], m.s[:m.limit], e.a)
			if next < 0 {
				continue
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
		if m.retries > MAX_RETRIES {
			m.err = "retry-limit-in-match over"
			return false
		}
		return true
	}
	return false
}

// The callout of data `i` run as the match passes it, as Oniguruma's builtin is: false to fail here, `end` when it
// ends the match at this start, or the search with its error in m.err.
@(private = "file")
callout :: proc(m: ^Matcher, i: int) -> (ok: bool, end: bool) {
	c := m.re.callouts[i]
	count := &m.counts[i]
	switch c.kind {
	case .Error:
		if c.code != -1 { // ONIG_MISMATCH
			m.err = error_message(c.code)
		}
		return false, true
	case .Count, .Total_Count, .Max:
		if c.type != '>' && c.type != 'X' && c.type != '<' {
			m.err = "invalid callout arg"
			return false, true
		}
		if c.type != '<' {
			if c.kind == .Max && count^ >= operand(m, c.sides[0]) {
				return false, false
			}
			count^ += 1
		}
		if c.type != '>' {
			if len(m.stack) >= MAX_STACK {
				m.err = "match-stack limit over"
				return false, true
			}
			push(m, {kind = .Retract, a = i})
		}
		return true, false
	case .Cmp:
		x, y := operand(m, c.sides[0]), operand(m, c.sides[1])
		switch c.op {
		case "==":
			return x == y, false
		case "!=":
			return x != y, false
		case "<":
			return x < y, false
		case ">":
			return x > y, false
		case "<=":
			return x <= y, false
		case ">=":
			return x >= y, false
		}
		m.err = "invalid callout arg"
		return false, true
	case .Begin_Buf, .End_Buf, .Semi_End_Buf, .Begin_Line, .End_Line, .Word_Boundary, .Not_Word_Boundary,
	     .Search_Start, .Fail, .Mismatch, .Skip:
	}
	return true, false
}

// The callout of data `i` as the match backs past it: '<' counts up to its most, 'X' takes back its count.
@(private = "file")
retract :: proc(m: ^Matcher, i: int) {
	c := m.re.callouts[i]
	switch {
	case c.type == 'X':
		m.counts[i] -= 1
	case c.kind != .Max || m.counts[i] < operand(m, c.sides[0]):
		m.counts[i] += 1
	}
}

@(private = "file")
operand :: #force_inline proc(m: ^Matcher, o: Operand) -> int {
	if o.ref == nil {
		return o.n
	}
	return m.counts[o.ref.index]
}

// Oniguruma's message for its error `code`, as onig_error_code_to_str gives it with no details: a code whose
// message names a detail is taken as one (*ERROR) may not give.
@(private = "file", rodata)
ERROR_MESSAGES := [?]struct {
	code: int,
	text: string,
}{
	{-2, "no support in this configuration"},
	{-3, "abort"},
	{-5, "fail to memory allocation"},
	{-6, "undefined type (bug)"},
	{-11, "internal parser error (bug)"},
	{-12, "stack error (bug)"},
	{-13, "undefined bytecode (bug)"},
	{-14, "unexpected bytecode (bug)"},
	{-15, "match-stack limit over"},
	{-16, "parse depth limit over"},
	{-17, "retry-limit-in-match over"},
	{-18, "retry-limit-in-search over"},
	{-19, "subexp-call-limit-in-search over"},
	{-21, "default multibyte-encoding is not set"},
	{-22, "can't convert to wide-char on specified multibyte-encoding"},
	{-23, "fail to initialize"},
	{-30, "invalid argument"},
	{-100, "end pattern at left brace"},
	{-101, "end pattern at left bracket"},
	{-102, "empty char-class"},
	{-103, "premature end of char-class"},
	{-104, "end pattern at escape"},
	{-105, "end pattern at meta"},
	{-106, "end pattern at control"},
	{-108, "invalid meta-code syntax"},
	{-109, "invalid control-code syntax"},
	{-110, "char-class value at end of range"},
	{-111, "char-class value at start of range"},
	{-112, "unmatched range specifier in char-class"},
	{-113, "target of repeat operator is not specified"},
	{-114, "target of repeat operator is invalid"},
	{-115, "nested repeat operator"},
	{-116, "unmatched close parenthesis"},
	{-117, "end pattern with unmatched parenthesis"},
	{-118, "end pattern in group"},
	{-119, "undefined group option"},
	{-120, "invalid group option"},
	{-121, "invalid POSIX bracket type"},
	{-122, "invalid pattern in look-behind"},
	{-123, "invalid repeat range {lower,upper}"},
	{-200, "too big number"},
	{-201, "too big number for repeat range"},
	{-202, "upper is smaller than lower in repeat range"},
	{-203, "empty range in char class"},
	{-204, "mismatch multibyte code length in char-class range"},
	{-205, "too many multibyte code ranges are specified"},
	{-206, "too short multibyte code string"},
	{-207, "too big backref number"},
	{-208, "invalid backref number/name"},
	{-209, "numbered backref/call is not allowed. (use name)"},
	{-210, "too many captures"},
	{-212, "too long wide-char value"},
	{-213, "undefined operator"},
	{-214, "group name is empty"},
	{-221, "never ending recursion"},
	{-222, "group number is too big for capture history"},
	{-224, "invalid if-else syntax"},
	{-225, "invalid absent group pattern"},
	{-226, "invalid absent group generator pattern"},
	{-227, "invalid callout pattern"},
	{-228, "invalid callout name"},
	{-229, "undefined callout name"},
	{-231, "invalid callout tag name"},
	{-232, "invalid callout arg"},
	{-400, "invalid code point value"},
	{-401, "too big wide-char value"},
	{-402, "not supported encoding combination"},
	{-403, "invalid combination of options"},
	{-406, "very inefficient pattern"},
	{-500, "library is not initialized"},
}

@(private = "file")
error_message :: proc(code: int) -> string {
	for e in ERROR_MESSAGES {
		if e.code == code {
			return e.text
		}
	}
	if (code >= 0 && code < max(int)) || code == -223 || code == -230 || (code >= -220 && code <= -215) {
		return "invalid callout body"
	}
	return "undefined error code"
}

@(private = "file")
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
		// Oniguruma reads the character after the text's start only short of an absent operator's limit
		// (DATA_ENSURE), and elsewhere up to the text's end.
		if pos < (m.limit if pos == 0 else len(s)) {
			r, _ := decode(s, pos)
			after = is_word(r)
		}
		return (before != after) == (kind == .Word_Boundary)
	case .Search_Start:
		return pos == m.start
	case .Skip:
		return true
	case .Fail, .Mismatch, .Error, .Count, .Total_Count, .Max, .Cmp:
	}
	return false
}

// The position after the text of the latest of the backreference's groups that matches at `pos`, or -1.
@(private = "file")
backref :: proc(m: ^Matcher, ins: Inst, pos: int) -> int {
	s := m.s[:m.limit] // the group's text may lie past the limit, which reads up to it
	groups := m.re.refs[ins.a]
	#reverse for g in groups {
		lo, hi := m.slots[2 * g], m.slots[2 * g + 1]
		if lo < 0 || hi < 0 {
			continue
		}
		text := m.s[lo:hi]
		if ins.b == 0 {
			if strings.has_prefix(s[pos:], text) {
				return pos + len(text)
			}
			continue
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
