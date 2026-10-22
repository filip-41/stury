package scan

import "core:bytes"
import "core:simd"
import "core:slice"
import core_pkg "../../core"
import lex "lex"

// The grammar a source is read in. `.Jsonc` is JSON with comments and trailing commas. Its walk is a
// specialization of its own (`jsonc_walk`), reached only when the dialect is asked for.
Dialect :: enum u8 {
	Json,
	Jsonc,
}

// Whitespace for the JSONC walk: comments are spans, and a `/` that does not open one is a fault.
// The byte cursor's skip does not call this, and `walk_value` does not build it. `facts` receives each
// comment, attached to nothing yet. `json` reads JSON's grammar instead, no comment and no trailing comma:
// `walk_deep` reads both dialects on this cursor.
Jsonc_Cursor :: struct {
	facts: ^[dynamic]Fact,
	fault: Maybe(Error),
	oom:   bool,
	json:  bool,
}

jsonc_cursor_advance :: #force_inline proc(_: ^Jsonc_Cursor) {}

jsonc_cursor_scalar_known :: #force_inline proc(_: ^Scanner, _: ^Jsonc_Cursor, $Q: bit_set[Walk_Kind]) -> bool {
	return false
}

jsonc_cursor_string_known :: #force_inline proc(
	_: ^Scanner,
	_: ^Jsonc_Cursor,
	$check: Check_Level,
	$Q: bit_set[Walk_Kind],
	_: bool,
) -> bool {
	return false
}

// Skip JSON whitespace and comments. A comment is only recognised where whitespace is, so a `//` or
// `/*` inside a string is never one. An unclosed block comment is `.Truncated`. A comment's bytes are checked
// as a string's raw bytes are: wire UTF-8, and no control byte but a tab, a line comment's line break, or
// a block comment's CR and LF.
jsonc_skip :: proc(s: ^Scanner, cur: ^Jsonc_Cursor) {
	if cur.fault != nil {
		return
	}
	for {
		lex.skip_ws(s)
		n := u64(len(s.src))
		if s.pos >= n || s.src[s.pos] != '/' || cur.json {
			return
		}
		if s.pos+1 >= n {
			cur.fault = Error{kind = .Bad_Char, offset = s.pos}
			return
		}
		lo := s.pos
		switch s.src[s.pos+1] {
		case '/':
			// CR is JSON whitespace, so it ends a line as LF does.
			s.pos += 2
			for s.pos < n {
				jsonc_comment_run(s, n, false)
				if s.pos >= n {
					break
				}
				b := s.src[s.pos]
				if b - 0x20 < 0x60 {
					s.pos += 1
				} else if b == '\n' || b == '\r' {
					break
				} else if !jsonc_comment_char(s, cur) {
					return
				}
			}
			jsonc_note(cur, lo, s.pos)
		case '*':
			s.pos += 2
			closed := false
			for s.pos < n {
				jsonc_comment_run(s, n, true)
				if s.pos >= n {
					break
				}
				b := s.src[s.pos]
				if b - 0x20 < 0x60 {
					if b == '*' && s.pos+1 < n && s.src[s.pos+1] == '/' {
						s.pos += 2
						closed = true
						break
					}
					s.pos += 1
				} else if b == '\n' || b == '\r' {
					s.pos += 1
				} else if !jsonc_comment_char(s, cur) {
					return
				}
			}
			if !closed {
				cur.fault = Error{kind = .Truncated, offset = n}
				s.pos = n
				return
			}
			jsonc_note(cur, lo, s.pos)
		case:
			cur.fault = Error{kind = .Bad_Char, offset = s.pos}
			return
		}
	}
}

// Steps over a comment's bytes 16 at a time while they are printable ASCII, and under `block` no `*`. It
// stops on the first other byte, or where fewer than 16 bytes are left, for the byte loop to check.
@(private)
jsonc_comment_run :: #force_inline proc(s: ^Scanner, n: u64, $block: bool) {
	when !SCAN_FORCE_SLOW {
		for s.pos + 16 <= n {
			v := lex.load16(s.src, s.pos)
			stop := simd.lanes_ge(v - 0x20, 0x60)
			when block {
				stop |= simd.lanes_eq(v, '*')
			}
			if lex.any_lane(stop) {
				s.pos += lex.first_stop_lane(stop)
				return
			}
			s.pos += 16
		}
	}
}

// A comment's byte at `s.pos` that is neither printable ASCII nor a line break, checked as a string's raw
// byte is: a tab passes, another control byte is `.Bad_Char`, and a UTF-8 sequence is stepped over or
// refused as `utf8_step_checked` refuses it. False, with the fault on `cur` and `s.pos` on its byte, when
// refused.
@(private, cold)
jsonc_comment_char :: proc(s: ^Scanner, cur: ^Jsonc_Cursor) -> bool {
	b := s.src[s.pos]
	if b == '\t' {
		s.pos += 1
		return true
	}
	if b < 0x80 {
		cur.fault = Error{kind = .Bad_Char, offset = s.pos}
		return false
	}
	if err := lex.utf8_step_checked(s); err != nil {
		cur.fault = err
		return false
	}
	return true
}

@(private)
jsonc_note :: proc(cur: ^Jsonc_Cursor, lo, hi: u64) {
	if cur.facts != nil {
		if _, err := append(cur.facts, Fact{lo = lo, hi = hi, node = NO_NODE}); err != nil {
			cur.oom = true
		}
	}
}

// The JSONC walk of the value at `s.pos`, which a `jsonc_skip` has already reached: a complete `.Values`
// walk for the kinds in `$Q`, never skipping and never stopping. A comment's fault outranks the walk's, which
// only met the byte the comment left it on. `s` holds a cap of at most MAX_DEPTH (`jsonc_walk_deep` takes a
// larger one).
jsonc_walk :: #force_no_inline proc(s: ^Scanner, q: ^Query_Ctx, $Q: bit_set[Walk_Kind], cur: ^Jsonc_Cursor) -> Maybe(Error) {
	err := walk_value_q(s, q, s.limits.max_depth, .Values, Q, cur, false, false)
	if cur.fault != nil {
		return cur.fault
	}
	return err
}

// `jsonc_walk` under a cap past MAX_DEPTH, on `walk_deep`.
jsonc_walk_deep :: proc(s: ^Scanner, q: ^Query_Ctx, $Q: bit_set[Walk_Kind], cur: ^Jsonc_Cursor) -> Maybe(Error) {
	err := walk_deep(s, q, s.limits.max_depth, .Values, Q, cur, false, nil)
	if cur.fault != nil {
		return cur.fault
	}
	return err
}

// `finish` for JSONC: comments may follow the value.
jsonc_finish :: proc(s: ^Scanner, cur: ^Jsonc_Cursor) -> Maybe(Error) {
	jsonc_skip(s, cur)
	if cur.fault != nil {
		return cur.fault
	}
	if s.pos != u64(len(s.src)) {
		return Error{offset = s.pos, kind = .Trailing}
	}
	return nil
}

// Check `src` as JSONC: comments and trailing commas, full grammar otherwise. `walk_value` is not this
// procedure. `facts` receives each comment, attached to nothing, and nil records none.
jsonc_validate :: proc(src: []byte, facts: ^[dynamic]Fact, limits := Limits{}) -> Maybe(Error) {
	s := enter_document(src, limits, DEPTH_CEILING)
	cur := Jsonc_Cursor{facts = facts}
	jsonc_skip(&s, &cur)
	err: Maybe(Error)
	if s.limits.max_depth > MAX_DEPTH {
		err = jsonc_walk_deep(&s, nil, {}, &cur)
	} else {
		err = jsonc_walk(&s, nil, {}, &cur)
	}
	if err == nil {
		err = jsonc_finish(&s, &cur)
	}
	if err == nil && cur.oom {
		return Error{kind = .Out_Of_Memory}
	}
	return err
}

// JSON's hooks for a JSONC scan: a path re-entry re-reads its array on the JSONC walk.
@(rodata)
FORMAT_HOOKS_JSONC := core_pkg.Format_Hooks{
	escaped_key_equals = name_equals,
	path_subwalk = path_subwalk_jsonc,
	dom_unescape_into = dom_unescape_into,
}

@(private = "file")
path_subwalk_jsonc :: proc(s: ^core_pkg.Scanner, ctx: ^core_pkg.Query_Ctx, max_depth: u64, halted: ^bool) -> Maybe(Error) {
	if max_depth > MAX_DEPTH {
		return walk_deep(s, ctx, max_depth, .Values, {.Path}, &Jsonc_Cursor{}, true, halted)
	}
	return walk_value_q(s, ctx, max_depth, .Values, {.Path}, &Jsonc_Cursor{}, false, true, halted)
}

// Attach each comment of `facts`, in source order and attached to nothing, to a row of `nodes`, the whole
// document's rows in preorder, then sort them by node, place, then source order.
//
// A comment inside a member, between its key and its value, is that member's `.Inline`. One on the line an
// entry ends on, after it, its comma or another such comment, is its `.Trail`, and so is one before the
// entry's comma on a later line, so an entry's comments never reach past its comma. Otherwise it is the
// `.Lead` of the next entry of its container, or, past the last, the container's `.Foot`. Outside the root a
// comment leads the root before it and trails it after.
//
// The containers open past MAX_DEPTH, under a raised `max_depth`, spill to `context.allocator`. False when
// it refuses, the facts then part attached.
jsonc_attach :: proc(nodes: []Row, src: []byte, facts: []Fact) -> bool {
	fixed: [MAX_DEPTH]Attach_Open = ---
	stack := ([^]Attach_Open)(&fixed)
	room := MAX_DEPTH
	spill: []Attach_Open
	defer if spill != nil {
		delete(spill)
	}
	depth := 0
	root_last := NO_NODE
	r := Node(0)
	n_rows := Node(len(nodes))
	for &cm, k in facts {
		// Every entry starting before the comment is placed under the container holding it.
		for r < n_rows && u64(entry_lo(nodes[r])) < cm.lo {
			at := entry_lo(nodes[r])
			for depth > 0 && nodes[stack[depth - 1].row].hi <= at {
				depth -= 1
			}
			if depth > 0 {
				stack[depth - 1].last = r
			} else {
				root_last = r
			}
			if nodes[r].kind == .Array || nodes[r].kind == .Object {
				if depth == room {
					if stack = attach_grow(&spill, stack, &room); stack == nil {
						return false
					}
				}
				stack[depth] = {row = r, last = NO_NODE}
				depth += 1
			}
			r += 1
		}
		for depth > 0 && u64(nodes[stack[depth - 1].row].hi) <= cm.lo {
			depth -= 1
		}
		parent := stack[depth - 1].row if depth > 0 else NO_NODE
		last := stack[depth - 1].last if depth > 0 else root_last
		cm.node, cm.place = 0, .Trail
		switch {
		case depth > 0 && cm.lo < u64(nodes[stack[depth - 1].row].lo):
			// The container's key came before the comment and its open bracket comes after.
			cm.node, cm.place = stack[depth - 1].row, .Inline
		case last >= 0 && nodes[last].key_lo != core_pkg.NO_KEY && cm.lo < u64(nodes[last].lo):
			cm.node, cm.place = last, .Inline
		case last >= 0 && (!bytes.contains_any(src[nodes[last].hi:cm.lo], {'\r', '\n'}) || comma_follows(src, facts, k)):
			cm.node, cm.place = last, .Trail
		case r < n_rows && (parent < 0 || entry_lo(nodes[r]) < nodes[parent].hi):
			cm.node, cm.place = r, .Lead
		case parent >= 0:
			cm.node, cm.place = parent, .Foot
		}
	}
	// Comments that only lead entries come out in order: one pass checks, where a sort moved every fact.
	if !slice.is_sorted_by(facts, fact_before) {
		slice.sort_by(facts, fact_before)
	}
	return true
}

@(private = "file")
Attach_Open :: struct {
	row, last: Node,
}

// `jsonc_attach`'s stack doubled onto `context.allocator`. Nil when it refuses, the old stack then kept.
@(private = "file", cold)
attach_grow :: proc(spill: ^[]Attach_Open, stack: [^]Attach_Open, room: ^int) -> [^]Attach_Open {
	grown, err := make([]Attach_Open, 2 * room^)
	if err != nil {
		return nil
	}
	copy(grown, stack[:room^])
	delete(spill^)
	spill^, room^ = grown, len(grown)
	return raw_data(grown)
}

// A document's order of facts: by node, then place, then source order.
@(private = "file")
fact_before :: proc(a, b: Fact) -> bool {
	if a.node != b.node {
		return a.node < b.node
	}
	if a.place != b.place {
		return a.place < b.place
	}
	return a.lo < b.lo
}

// Whether the byte after comment `k`, past blanks and the comments that follow it, is a comma. Reads only
// the spans, which attaching leaves as they are.
@(private = "file")
comma_follows :: proc(src: []byte, facts: []Fact, k: int) -> bool {
	s := Scanner{src = src, pos = facts[k].hi}
	for j := k + 1; ; j += 1 {
		lex.skip_ws(&s)
		if j == len(facts) || facts[j].lo != s.pos {
			return lex.peek(&s) == ','
		}
		s.pos = facts[j].hi
	}
}

// Where row `n`'s entry starts in its container: its key, or its value when it has none.
entry_lo :: #force_inline proc(n: Row) -> u32 {
	return n.lo if n.key_lo == core_pkg.NO_KEY else n.key_lo
}
