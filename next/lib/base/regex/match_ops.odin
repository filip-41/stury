#+private
package regex

// Cold, out-of-line matcher operations: group unsetting, subexpression calls and absent-operator limits,
// zero-width assertions, backreferences, and \R linebreaks.

import "core:strings"
import "stury:lib/base/spell"

@(private = "file")
MAX_CALL_NEST :: 20 // Oniguruma's subexp_call_nest_counter limit as jq builds it, a group in place counted

unset_slots :: proc(m: ^Matcher, lo, hi: i32, $SET: bool) -> bool {
	for k in lo ..< hi {
		if m.slots[k] >= 0 {
			save_slot(m, int(k), -1, SET) or_return
		}
	}
	return true
}

// Executes the ops of subexpression calls and the absent operator. They are kept out of `run`'s loop so that patterns
// without them (`Regex.calls_or_limits` false) run with no tracking for them.
call_or_limit :: #force_no_inline proc(m: ^Matcher, op: Op, a: i32, pc: ^int, pos: int) -> bool {
	slots := m.slots
	#partial switch op {
	case .Call:
		if m.depth >= MAX_CALL_NEST {
			return false
		}
		push(m, {kind = .Call_Frame, pc = i32(pc^ + 1)}, false) or_return
		m.depth += 1
		pc^ = int(a)
	case .Return:
		pc^ = int(latest_open(m.stack[:], .Call_Frame, .Return, 0).pc)
		push(m, {kind = .Return}, false) or_return
		m.depth -= 1
	case .Mem_Start:
		g := int(a)
		save_slot(m, 2 * g, pos, false) or_return
		save_slot(m, 2 * g + 1, -1, false) or_return
		push(m, {kind = .Mem_Start, a = g, b = pos}, false) or_return
		pc^ += 1
	case .Mem_End:
		// The start of this group's own run, skipping the starts and ends of runs it called.
		g := int(a)
		start := latest_open(m.stack[:], .Mem_Start, .Mem_End, g).b
		save_slot(m, 2 * g, start, false) or_return
		save_slot(m, 2 * g + 1, pos, false) or_return
		push(m, {kind = .Mem_End, a = g}, false) or_return
		pc^ += 1
	case .Limit_Save:
		save_slot(m, int(a), m.limit, false) or_return
		push(m, {kind = .Limit, a = m.limit}, false) or_return
		pc^ += 1
	case .Limit_Cut:
		m.limit = slots[a]
		pc^ += 1
	case .Limit_Restore, .Limit_Clear:
		push(m, {kind = .Limit, a = m.limit}, false) or_return
		m.limit = max(slots[a], pos) if op == .Limit_Restore else len(m.s)
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
				r, _ = decode(s, spell.char_start(s, pos - 1))
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
backref :: proc(m: ^Matcher, ref, flag: i32, pos: int) -> int {
	s := m.s[:m.limit] // the group's text may lie past the limit, but the match reads only up to it
	groups := m.re.refs[ref]
	#reverse for g in groups {
		lo, hi := m.slots[2 * g], m.slots[2 * g + 1]
		if lo < 0 || hi < 0 {
			if m.re.ecma {
				return pos
			}
			continue
		}
		text := m.s[lo:hi]
		if flag == 0 {
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
		for q := 0; q < len(text); {
			if p >= len(s) {
				matched = false
				break
			}
			want, ww := decode(text, q)
			r, w := decode(s, p)
			if fold(r) != fold(want) {
				matched = false
				break
			}
			q += ww
			p += w
		}
		if matched {
			return p
		}
	}
	return -1
}

// \R: "\r\n", or one of "\n" "\v" "\f" "\r" U+0085 U+2028 U+2029.
linebreak :: proc(s: string, pos: int) -> int {
	if pos >= len(s) {
		return -1
	}
	if strings.has_prefix(s[pos:], "\r\n") {
		return pos + 2
	}
	if spell.is_continuation(s[pos]) {
		return -1 // inside a character: U+0085 is not its trailing byte
	}
	r, w := decode(s, pos)
	switch r {
	case '\n', '\v', '\f', '\r', 0x85, 0x2028, 0x2029:
		return pos + w
	}
	return -1
}
