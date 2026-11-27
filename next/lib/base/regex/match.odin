#+private
package regex

// The backtracking matcher. It tries a program's alternatives in order as Oniguruma does, so its matches and captures
// are Oniguruma's. Its stack is capped, where Oniguruma's grows without bound. search.odin runs it.

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/spell"

@(private = "file")
MAX_STACK :: 1 << 23 when size_of(int) == 8 else 1 << 21 // entries (24 B on 64-bit, 16 B on 32-bit)

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

Entry :: struct {
	kind: Entry_Kind,
	pc:   i32,
	a, b: int,
}

// Returns the character at `pos` and its width. A byte below 0xC0 is read as the code point of its value, as Oniguruma
// reads a continuation byte where jq's global search starts inside a character.
decode :: #force_inline proc(s: string, pos: int) -> (rune, int) {
	if s[pos] < 0xC0 {
		return rune(s[pos]), 1
	}
	return utf8.decode_rune_in_string(s[pos:])
}

// Returns the position after what the Str, Any, Any_All, Class or Char_Fold instruction `ins` matches at `pos`, or -1.
step :: #force_inline proc(re: ^Regex, ins: Inst, s: string, pos: int) -> int {
	if pos >= len(s) {
		return -1
	}
	#partial switch ins.op {
	case .Str:
		lit := re.bytes[ins.a:][:ins.b]
		return pos + len(lit) if strings.has_prefix(s[pos:], lit) else -1
	case .Any, .Any_All:
		if ins.op == .Any && s[pos] == '\n' {
			return -1
		}
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

// Pushes an entry onto the match stack. Growth goes through `grow_stack`, which enforces `MAX_STACK` / `m.room` and
// reports allocator failure with `MEMORY_OUT`.
push :: #force_inline proc(m: ^Matcher, e: Entry, $SET: bool) -> bool {
	raw := (^runtime.Raw_Dynamic_Array)(m.stack)
	if raw.len >= raw.cap {
		grow_stack(m, SET) or_return
	}
	#no_bounds_check ([^]Entry)(raw.data)[raw.len] = e
	raw.len += 1
	return true
}

@(private = "file")
grow_stack :: #force_no_inline proc(m: ^Matcher, $SET: bool) -> bool {
	limit := MAX_STACK
	when SET {
		if 2 * (len(m.stack) * size_of(Entry) + len(m.log) * size_of(u32)) >= m.room {
			m.err = MEMORY_OUT
			return false
		}
		limit = max(m.room / (2 * size_of(Entry)), 1)
	} else {
		if len(m.stack) >= MAX_STACK {
			m.err = {.Memory, "match-stack limit over"}
			return false
		}
	}
	next_cap := min(max(cap(m.stack) * 2, 8), limit)
	if err := non_zero_reserve(m.stack, max(next_cap, len(m.stack) + 1)); err != nil {
		m.err = MEMORY_OUT
		return false
	}
	return true
}

save_slot :: #force_inline proc(m: ^Matcher, slot, val: int, $SET: bool) -> bool {
	push(m, {kind = .Restore, a = slot, b = m.slots[slot]}, SET) or_return
	m.slots[slot] = val
	return true
}

// Pushes an alternative. At MAX_STACK entries it sets Oniguruma's error and returns false. With `$SET` it sets the
// memory error instead once the stack and the log may take `m.room` bytes, the room beside the sets.
push_branch :: #force_inline proc(m: ^Matcher, e: Entry, $SET: bool) -> bool {
	when SET {
		if 2 * (len(m.stack) * size_of(Entry) + len(m.log) * size_of(u32)) >= m.room {
			m.err = MEMORY_OUT
			return false
		}
	}
	return push(m, e, SET)
}

@(private = "file")
branch :: #force_inline proc(m: ^Matcher, target: i32, pos: int, $SET: bool) -> bool {
	return push_branch(m, {kind = .Branch, pc = target, a = pos, b = len(m.log) when SET else 0}, SET)
}

@(private = "file")
charge_retry :: #force_inline proc(m: ^Matcher, $SET: bool) -> bool {
	when SET {
		if m.limited && over_budget(m) {
			return false
		}
		m.retries += 1
	} else {
		m.retries += 1
		if m.retries > m.retry_cap {
			m.err = STEPS_OUT
			return false
		}
	}
	return true
}

// Runs the program from `at`: true on a match (written to m.caps), false on none or on an error in m.err.
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
			m.earlier += u64(m.retries)
			m.retries = 0
			if m.limited {
				allowed := u64(m.allowed)
				left := allowed - m.earlier if m.earlier < allowed else 0
				m.retry_cap = min(m.retry_cap, int(left))
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
				if m.good != nil && in_good(m, row, pos) {
					look := int(re.visited.owner[pc])
					if insts[look + 1].op != .Unset || len(m.caps) <= 2 {
						pc = int(insts[look].b)
						ins = insts[pc]
					}
				} else {
					ok = false
				}
			}
		}
		if ok {
			switch ins.op {
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
				branch(m, ins.b, pos, SET) or_return
				pc = int(ins.a)
			case .Split_Head:
				if pos >= len(s) || s[pos] != byte(ins.a) {
					pc = int(ins.b)
					continue
				}
				branch(m, ins.b, pos, SET) or_return
				pc += 1
			case .Jmp:
				pc = int(ins.a)
			case .Save:
				save_slot(m, int(ins.a), pos, SET) or_return
				if ins.b != 0 {
					// Oniguruma pushes a referenced group's start (OP_MEM_START_PUSH), which unsets its end until
					// the group closes again. A backreference or condition inside the group sees it unset, and never
					// a start past the last iteration's end.
					save_slot(m, int(ins.a) + 1, -1, SET) or_return
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
				next := backref(m, ins.a, ins.b, pos)
				ok = next >= 0
				pos = next
				pc += 1
			case .Look:
				push(m, {kind = .Barrier, pc = i32(pc), a = pos, b = len(m.log) when SET else 0}, SET) or_return
				when SET {
					m.looking += 1
				}
				pc += 1
			case .Look_End:
				k := len(m.stack) - 1
				for k >= 0 && m.stack[k].kind != .Barrier {
					k -= 1
				}
				if k < 0 { // the push of the Barrier failed
					m.err = MEMORY_OUT
					return false
				}
				bar := m.stack[k]
				when SET {
					settle(m, bar)
				}
				switch kind := Look_Kind(insts[bar.pc].a); kind {
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
					if kind == .Ahead || kind == .Behind && re.ecma {
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
					pos = spell.char_start(s, pos - 1)
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
				unset_slots(m, ins.a, ins.b, SET) or_return
				pc += 1
			case .Cond:
				pc = pc + 1 if slots[2 * ins.a + 1] >= 0 else int(ins.b)
			case .Linebreak:
				// Oniguruma's \R is (?>\r\n|[\n\v\f\r\x{85}\x{2028}\x{2029}]), whose second alternative costs a retry.
				next := linebreak(s, pos)
				if next != pos + 2 || s[pos] != '\r' {
					charge_retry(m, SET) or_return
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
						push(m, {kind = .Take_More, pc = i32(pc), a = p, b = count}, SET) or_return
					}
				} else {
					lo := p
					// With `$SET` an unbounded repeat marks each stop past where it began in its body's row, which `run`
					// never visits. It walks no further than a stop an earlier walk marked, because that walk tries the
					// stops from there. Past where it began, no loop iteration has matched nothing, so the row is the
					// first.
					when SET {
						row := stop_row(m, pc)
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
						push(m, {kind = .Give_Back, pc = i32(pc), a = p, b = lo}, SET) or_return
					}
					if count < int(ins.b) {
						// Oniguruma keeps an alternative for each optional copy it tries, so the copy that does
						// not match costs it a retry.
						charge_retry(m, SET) or_return
					}
				}
				pos = p
				pc += 2
			case .Count_Reset:
				save_slot(m, int(ins.a), 0, SET) or_return
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
				branch(m, ins.b if ins.op == .Count else i32(pc + 2), pos, SET) or_return
				pc = pc + 2 if ins.op == .Count else int(ins.b)
			case .Count_Next:
				save_slot(m, int(ins.a), slots[ins.a] + 1, SET) or_return
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
					ok = call_or_limit(m, ins.op, ins.a, &pc, pos)
					if !ok && m.err.kind != .None {
						return false
					}
					s = m.s[:m.limit]
				} else {
					unreachable()
				}
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

// Whether the retries have used the search's budget, with the error set when they have.
@(private = "file")
over_budget :: #force_inline proc(m: ^Matcher) -> bool {
	if m.retries < m.budget {
		return false
	}
	m.err = STEPS_OUT if m.limited else BUDGET_OUT
	return true
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
				// The engine's own budget counts only the stops of bounded repeats, which can outnumber the pairs.
				if m.limited && over_budget(m) {
					return false
				}
				resize(m.log, int(e.b))
			}
			pc^, pos^ = int(e.pc), e.a
		case .Give_Back:
			// Every other entry was pushed at a pair's first visit, so only a bounded repeat's stops, given back or
			// taken lazily, can outnumber the pairs and spend the budget.
			when SET {
				if over_budget(m) {
					return false
				}
			}
			// Gives back a character, checking that the preceding lead actually decodes to `e.a` so lone continuation
			// bytes in invalid UTF-8 (and repeats started inside a character) step back one byte at a time.
			p := e.a - 1
			if spell.is_continuation(m.s[p]) {
				q := p
				for q > e.b && spell.is_continuation(m.s[q]) {
					q -= 1
				}
				if _, w := decode(m.s, q); q + w == e.a {
					p = q
				}
			}
			if p > e.b {
				push(m, {kind = .Give_Back, pc = e.pc, a = p, b = e.b}, SET) or_return
			}
			pc^, pos^ = int(e.pc) + 2, p
		case .Take_More:
			when SET {
				if over_budget(m) {
					return false
				}
			}
			rep := m.re.insts[e.pc]
			next := step(m.re, m.re.insts[e.pc + 1], m.s[:m.limit], e.a)
			if next < 0 {
				continue
			}
			when SET {
				// as a greedy repeat marks its stops
				if rep.b < 0 && !first_visit(m, row_of(m, int(e.pc) + 1, next), next) {
					continue
				}
			}
			if rep.b < 0 || e.b + 1 < int(rep.b) {
				push(m, {kind = .Take_More, pc = e.pc, a = next, b = e.b + 1}, SET) or_return
			}
			pc^, pos^ = int(e.pc) + 2, next
		case:
			undo(m, e, EXT)
			continue
		}
		m.retries += 1
		when !SET {
			if m.retries > m.retry_cap {
				m.err = STEPS_OUT
				return false
			}
		}
		return true
	}
	return false
}
