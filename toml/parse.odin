#+private
package toml

import "base:runtime"
import core "../core"

// Reads a text into a `Table_Tree`. The statements of a text are keys with values and table headers, one to a line, and a
// value may hold arrays and inline tables inside one another. An explicit stack of open containers reads those, so
// nesting costs the heap and not the call stack.

Parser :: struct {
	src:       []u8,
	pos:       int,
	v11:       bool,
	tree:      Table_Tree,
	cur:       u32, // the table the statements add to
	fail:      u64, // the fault's result word, 0 for none
	pending:   u32, // the first comment no node has taken
	last:      u32, // the value that most recently ended, which a comment on its line belongs to
	inline_ok: bool, // no line end has passed since `last` ended
	parts:     [dynamic]Part,
	stack:     [dynamic]u32,
}

parser_init :: proc "contextless" (p: ^Parser, src: []u8, v11: bool, max_depth: u32) -> bool {
	context = runtime.default_context()
	p^ = Parser{src = src, v11 = v11, last = NIL}
	if !tree_init(&p.tree, max_depth, len(src)) {
		return false
	}
	p.parts = make([dynamic]Part, 0, 4)
	p.stack = make([dynamic]u32, 0, 8)
	return p.parts != nil && p.stack != nil
}

parser_destroy :: proc "contextless" (p: ^Parser) {
	context = runtime.default_context()
	delete(p.parts)
	delete(p.stack)
	tree_destroy(&p.tree)
}

fault :: proc "contextless" (p: ^Parser, at: int, kind: core.Fault_Kind, detail: Detail) -> bool {
	p.fail = core.fault_at(u64(at), kind, u8(detail))
	return false
}

// Turns the tree's refusal `r` of an insertion at byte `at` into its fault, and returns whether there was none.
refused :: proc "contextless" (p: ^Parser, r: Refusal, at: int) -> bool {
	switch r {
	case .None:
		return true
	case .Redefined:
		return fault(p, at, .Bad_Char, .Redefined_Table)
	case .Duplicate:
		return fault(p, at, .Bad_Char, .Duplicate_Key)
	case .Inline:
		return fault(p, at, .Bad_Char, .Extends_Inline)
	case .Static:
		return fault(p, at, .Bad_Char, .Extends_Array)
	case .Not_Table:
		return fault(p, at, .Bad_Char, .Not_Table)
	case .Too_Deep:
		return fault(p, at, .Too_Deep, .None)
	case .No_Memory:
		return fault(p, 0, .No_Memory, .None)
	}
	return false
}

// Gives the comments above the next node to node `id`.
take_heads :: proc "contextless" (p: ^Parser, id: u32) {
	n := &p.tree.nodes[id]
	n.head, n.heads = p.pending, u32(len(p.tree.comments)) - p.pending
	p.pending = u32(len(p.tree.comments))
}

skip_ws :: #force_inline proc "contextless" (p: ^Parser) {
	for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') {
		p.pos += 1
	}
}

// Passes white space and comments, and line ends when `newlines`. A comment on the line where the last value ended is
// that value's, and any other waits for the node that follows.
blanks :: proc "contextless" (p: ^Parser, newlines: bool) -> bool {
	src := p.src
	for p.pos < len(src) {
		switch src[p.pos] {
		case ' ', '\t':
			p.pos += 1
		case '#':
			end, v := scan_comment(src, p.pos)
			if v != 0 {
				p.fail = v
				return false
			}
			c := Comment{u64(p.pos), u32(end - p.pos)}
			if p.inline_ok && p.last != NIL {
				p.tree.nodes[p.last].inline = c
			} else if !push_comment(&p.tree, c) {
				return fault(p, 0, .No_Memory, .None)
			}
			p.pos = end
		case '\n':
			if !newlines {
				return true
			}
			p.pos += 1
			p.inline_ok = false
		case '\r':
			if !newlines {
				return true
			}
			if p.pos + 1 >= len(src) || src[p.pos + 1] != '\n' {
				return fault(p, p.pos, .Bad_Char, .Lone_Cr)
			}
			p.pos += 2
			p.inline_ok = false
		case:
			return true
		}
	}
	return true
}

// Judges the end of a statement: a comment, then a line end or the text's end.
end_of_line :: proc "contextless" (p: ^Parser) -> bool {
	blanks(p, false) or_return
	if p.pos >= len(p.src) || p.src[p.pos] == '\n' {
		return true
	}
	if p.src[p.pos] == '\r' {
		if p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '\n' {
			return true
		}
		return fault(p, p.pos, .Bad_Char, .Lone_Cr)
	}
	return fault(p, p.pos, .Bad_Char, .Expected_Line_End)
}

bare_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b == '-'
}

// Reads one key at the position. A quoted key is a basic or literal string on one line.
simple_key :: proc "contextless" (p: ^Parser) -> (part: Part, ok: bool) {
	src := p.src
	if p.pos >= len(src) {
		return {}, fault(p, len(src), .Truncated, .Expected_Key)
	}
	lo := p.pos
	c := src[lo]
	switch {
	case bare_byte(c):
		end := lo + 1
		for end < len(src) && bare_byte(src[end]) {
			end += 1
		}
		p.pos = end
		return Part{core.Token{u64(lo), u32(end - lo), .String, .Key, 0}, string(src[lo:end])}, true
	case c == '"' || c == '\'':
		end: int
		v: Verdict
		style: Style
		if c == '"' {
			end, v = scan_basic(src, lo, p.v11)
			style = .Basic
		} else {
			end, v = scan_literal(src, lo)
			style = .Literal
		}
		if v != 0 {
			p.fail = v
			return {}, false
		}
		p.pos = end
		spelling := string_spelling(style)
		tok := core.Token{u64(lo), u32(end - lo), .String, .Key, spelling}
		inner := src[lo + 1:end - 1]
		escaped := false
		for b in inner {
			escaped ||= b == '\\'
		}
		if style == .Literal || !escaped {
			return Part{tok, string(inner)}, true
		}
		context = runtime.default_context()
		buf, err := runtime.arena_alloc(&p.tree.names, uint(max(len(inner), 1)), 1)
		if err != nil {
			return {}, fault(p, 0, .No_Memory, .None)
		}
		text, _ := decode(src[lo:end], spelling, buf)
		return Part{tok, text}, true
	}
	return {}, fault(p, lo, .Bad_Char, .Expected_Key)
}

// Reads a dotted key into `p.parts`.
key_path :: proc "contextless" (p: ^Parser) -> bool {
	context = runtime.default_context()
	clear(&p.parts)
	for {
		skip_ws(p)
		part := simple_key(p) or_return
		if _, err := append(&p.parts, part); err != nil {
			return fault(p, 0, .No_Memory, .None)
		}
		skip_ws(p)
		if p.pos < len(p.src) && p.src[p.pos] == '.' {
			p.pos += 1
			continue
		}
		return true
	}
}

// Reads `=` and the white space after it.
equals :: proc "contextless" (p: ^Parser) -> bool {
	if p.pos >= len(p.src) || p.src[p.pos] != '=' {
		return fault(p, p.pos, .Bad_Char, .Expected_Equals)
	}
	p.pos += 1
	skip_ws(p)
	return true
}

// Adds the member `p.parts` names to table `table`, a dotted key's tables on the way. Returns the new value slot. The
// comments above go to the first node the key made.
add_member :: proc "contextless" (p: ^Parser, table: u32) -> (slot: u32, ok: bool) {
	cur, first := table, NIL
	for i in 0 ..< len(p.parts) - 1 {
		id, created, r := dotted_step(&p.tree, cur, p.parts[i])
		refused(p, r, int(p.parts[i].tok.lo)) or_return
		if created && first == NIL {
			first = id
		}
		cur = id
	}
	last := p.parts[len(p.parts) - 1]
	id, r := leaf_key(&p.tree, cur, last)
	refused(p, r, int(last.tok.lo)) or_return
	take_heads(p, first if first != NIL else id)
	return id, true
}

// Reads a `key = value` statement into the current table.
key_value :: proc "contextless" (p: ^Parser) -> bool {
	key_path(p) or_return
	equals(p) or_return
	slot := add_member(p, p.cur) or_return
	return value_tree(p, slot)
}

// Reads a `[header]` or `[[header]]` statement and makes its table current.
header :: proc "contextless" (p: ^Parser) -> bool {
	src := p.src
	start := p.pos
	p.pos += 1
	array := p.pos < len(src) && src[p.pos] == '['
	if array {
		p.pos += 1
	}
	key_path(p) or_return
	for _ in 0 ..< 1 + int(array) {
		if p.pos >= len(src) || src[p.pos] != ']' {
			return fault(p, p.pos, .Truncated if p.pos >= len(src) else .Bad_Char, .Expected_Close)
		}
		p.pos += 1
	}
	cur := u32(0)
	for i in 0 ..< len(p.parts) - 1 {
		id, r := header_step(&p.tree, cur, p.parts[i])
		refused(p, r, int(p.parts[i].tok.lo)) or_return
		cur = id
	}
	last := p.parts[len(p.parts) - 1]
	id: u32
	r: Refusal
	if array {
		id, r = array_leaf(&p.tree, cur, last, u64(start))
	} else {
		id, r = header_leaf(&p.tree, cur, last, u64(start))
	}
	refused(p, r, int(last.tok.lo)) or_return
	take_heads(p, id)
	p.cur, p.last, p.inline_ok = id, id, true
	return true
}

// Ends the innermost open array or inline table at its closing byte.
close_top :: proc "contextless" (p: ^Parser) {
	context = runtime.default_context()
	top := pop(&p.stack)
	n := &p.tree.nodes[top]
	n.foot, n.foots = p.pending, u32(len(p.tree.comments)) - p.pending
	p.pending = u32(len(p.tree.comments))
	p.pos += 1
	p.last, p.inline_ok = top, true
}

// Reads the next member of the innermost open container, or closes it at its closing byte. Returns the new value slot,
// and `closed` when it closed.
next_child :: proc "contextless" (p: ^Parser, after_comma: bool) -> (slot: u32, closed: bool, ok: bool) {
	top := p.stack[len(p.stack) - 1]
	array := p.tree.nodes[top].kind == .Array
	blanks(p, array || p.v11) or_return
	if p.pos >= len(p.src) {
		return 0, false, fault(p, len(p.src), .Truncated, .Expected_Close)
	}
	c := p.src[p.pos]
	if c == (']' if array else '}') {
		if !array && after_comma && !p.v11 {
			return 0, false, fault(p, p.pos, .Bad_Char, .Trailing_Comma)
		}
		close_top(p)
		return 0, true, true
	}
	if c == ',' {
		return 0, false, fault(p, p.pos, .Bad_Char, .Expected_Value)
	}
	if array {
		id, r := add_node(&p.tree, top, Table_Node{kind = .Scalar}, false)
		refused(p, r, p.pos) or_return
		take_heads(p, id)
		return id, false, true
	}
	key_path(p) or_return
	equals(p) or_return
	slot = add_member(p, top) or_return
	return slot, false, true
}

// Sets node `id`'s scalar token, or fails on a token too long to hold.
set_scalar :: proc "contextless" (p: ^Parser, id: u32, lo, end: int, kind: core.Kind, spelling: u16) -> bool {
	if end - lo > int(max(u32)) {
		return fault(p, lo, .Too_Wide, .None)
	}
	p.tree.nodes[id].value = core.Token{u64(lo), u32(end - lo), kind, .Value, spelling}
	p.pos = end
	if end < len(p.src) && !terminator(p.src[end]) {
		return fault(p, end, .Bad_Char, .After_Value)
	}
	return true
}

push_open :: proc "contextless" (p: ^Parser, id: u32) -> bool {
	context = runtime.default_context()
	if _, err := append(&p.stack, id); err != nil {
		return fault(p, 0, .No_Memory, .None)
	}
	return true
}

// Reads one value into node `id`. Returns true in `opened` when it opened an array or an inline table, which stays open
// on the stack.
value :: proc "contextless" (p: ^Parser, id: u32) -> (opened: bool, ok: bool) {
	src := p.src
	skip_ws(p)
	if p.pos >= len(src) {
		return false, fault(p, len(src), .Truncated, .Expected_Value)
	}
	lo := p.pos
	c := src[lo]
	switch c {
	case '"', '\'':
		end: int
		v: Verdict
		style: Style
		multi := lo + 2 < len(src) && src[lo + 1] == c && src[lo + 2] == c
		switch {
		case c == '"' && multi:
			end, v = scan_multiline(src, lo, false, p.v11)
			style = .Multiline
		case c == '"':
			end, v = scan_basic(src, lo, p.v11)
			style = .Basic
		case multi:
			end, v = scan_multiline(src, lo, true, p.v11)
			style = .Multiline_Literal
		case:
			end, v = scan_literal(src, lo)
			style = .Literal
		}
		if v != 0 {
			p.fail = v
			return false, false
		}
		return false, set_scalar(p, id, lo, end, .String, string_spelling(style))
	case '[', '{':
		n := &p.tree.nodes[id]
		if n.depth + 1 > p.tree.max_depth {
			return false, fault(p, lo, .Too_Deep, .None)
		}
		n.value = core.Token{lo = u64(lo), kind = .Array if c == '[' else .Object}
		n.kind = .Array if c == '[' else .Table
		n.flags = {} if c == '[' else {.Inline}
		p.pos += 1
		p.inline_ok = false
		return true, push_open(p, id)
	case 't', 'f':
		word := "true" if c == 't' else "false"
		if lo + len(word) > len(src) || string(src[lo:lo + len(word)]) != word {
			return false, fault(p, lo, .Bad_Char, .Expected_Value)
		}
		return false, set_scalar(p, id, lo, lo + len(word), .True if c == 't' else .False, 0)
	case '+', '-', '0' ..= '9', 'i', 'n':
		if datetime_starts(src, lo) {
			end, kind, v := scan_datetime(src, lo, p.v11)
			if v != 0 {
				p.fail = v
				return false, false
			}
			return false, set_scalar(p, id, lo, end, .String, datetime_spelling(kind))
		}
		end, spelling, v := scan_number(src, lo)
		if v != 0 {
			p.fail = v
			return false, false
		}
		return false, set_scalar(p, id, lo, end, .Number, spelling)
	}
	return false, fault(p, lo, .Bad_Char, .Expected_Value)
}

// Reads the value of node `id` and the arrays and inline tables in it.
value_tree :: proc "contextless" (p: ^Parser, id: u32) -> bool {
	base := len(p.stack)
	cur := id
	opened := false
	for {
		if !opened {
			is_open, ok := value(p, cur)
			if !ok {
				return false
			}
			if !is_open {
				p.last, p.inline_ok = cur, true
			}
			opened = is_open
		}
		if opened {
			slot, closed, ok := next_child(p, false)
			if !ok {
				return false
			}
			if !closed {
				cur, opened = slot, false
				continue
			}
		}
		// A value has ended, and the open containers around it expect a comma or their close.
		opened = false
		for {
			if len(p.stack) == base {
				return true
			}
			top := p.stack[len(p.stack) - 1]
			array := p.tree.nodes[top].kind == .Array
			blanks(p, array || p.v11) or_return
			if p.pos >= len(p.src) {
				return fault(p, len(p.src), .Truncated, .Expected_Close)
			}
			c := p.src[p.pos]
			if c == (']' if array else '}') {
				close_top(p)
				continue
			}
			if c != ',' {
				return fault(p, p.pos, .Bad_Char, .Expected_Comma)
			}
			p.pos += 1
			slot, closed, ok := next_child(p, true)
			if !ok {
				return false
			}
			if !closed {
				cur = slot
				break
			}
		}
	}
}

// Reads the whole text into `p.tree`. Returns false with `p.fail` set at the first fault.
parse :: proc "contextless" (p: ^Parser, lo: u64) -> bool {
	p.pos = int(core.text_start(p.src, min(lo, u64(len(p.src)))))
	for {
		blanks(p, true) or_return
		if p.pos >= len(p.src) {
			break
		}
		if p.src[p.pos] == '[' {
			header(p) or_return
		} else {
			key_value(p) or_return
		}
		end_of_line(p) or_return
	}
	root := &p.tree.nodes[0]
	root.foot, root.foots = p.pending, u32(len(p.tree.comments)) - p.pending
	p.pending = u32(len(p.tree.comments))
	return true
}
