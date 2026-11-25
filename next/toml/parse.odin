package toml

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Reads the statements of a text into a `Table_Tree`. The statements of a text are keys with values and table headers,
// one to a line, and a value may hold arrays and inline tables inside one another. An explicit stack of open
// containers reads those, so nesting costs the heap and not the call stack. The parser allocates in the context's
// allocator.

@(private)
Parser :: struct {
	src:       []u8,
	pos:       int,
	v11:       bool,
	tree:      Table_Tree,
	cur:       u32, // the table the statements add to
	fail:      hook.Walk_Result, // the fault, 0 for none
	pending:   u32, // the first comment no node has taken
	last:      u32, // the value that most recently ended, which a comment on its line belongs to
	inline_ok: bool, // no line end has passed since `last` ended
	done:      bool, // the text's end was read
	final:     bool, // the window `src` is ends the text, as a whole text's does
	own:       bool, // a key's name is copied out of `src`, which a text in pieces may not keep
	parts:     [dynamic]Part,
	stack:     [dynamic]u32,
}

@(private)
parser_init :: proc(p: ^Parser, src: []u8, v11: bool, max_depth: u64, tree_allocator: runtime.Allocator) -> bool {
	p^ = Parser{src = src, v11 = v11, last = NIL, final = true}
	if !tree_init(&p.tree, u32(min(max_depth, u64(max(u32)))), len(src), tree_allocator) {
		return false
	}
	err: runtime.Allocator_Error
	p.parts, err = make([dynamic]Part, 0, 4, tree_allocator)
	if err != nil {
		return false
	}
	p.stack, err = make([dynamic]u32, 0, 8, tree_allocator)
	return err == nil
}

@(private)
parser_destroy :: proc(p: ^Parser) {
	delete(p.parts)
	delete(p.stack)
	tree_destroy(&p.tree)
}

@(private)
fault :: proc "contextless" (p: ^Parser, at: int, kind: tape.Fault_Kind, detail: Detail) -> bool {
	p.fail = bad(at, kind, detail)
	return false
}

@(private, cold)
no_memory :: proc "contextless" (p: ^Parser) -> bool {
	p.fail = hook.walk_result(u64(p.pos), hook.WALK_NO_MEMORY)
	return false
}

// Turns the tree's refusal `r` of an insertion at byte `at` into its fault, and returns whether there was none.
@(private)
refused :: proc "contextless" (p: ^Parser, r: Tree_Refusal, at: int) -> bool {
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
		p.fail = hook.walk_result(u64(at), hook.WALK_TOO_DEEP)
		return false
	case .No_Memory:
		return no_memory(p)
	}
	return false
}

// Gives the comments above the next node to node `id`.
@(private)
take_heads :: #force_inline proc(p: ^Parser, id: u32) {
	if u32(len(p.tree.comments)) != p.pending {
		give_heads(p, id)
	}
}

@(private)
give_heads :: #force_no_inline proc(p: ^Parser, id: u32) {
	n := notes_for(&p.tree, id)
	n.head, n.heads = p.pending, u32(len(p.tree.comments)) - p.pending
	p.pending = u32(len(p.tree.comments))
}

@(private)
skip_ws :: #force_inline proc "contextless" (p: ^Parser) #no_bounds_check {
	for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') {
		p.pos += 1
	}
}

// Passes white space and comments, and line ends when `newlines`. A comment on the line where the last value ended is
// that value's, and any other waits for the node that follows.
@(private)
blanks :: proc(p: ^Parser, newlines: bool) -> bool #no_bounds_check {
	src := p.src
	k := p.pos
	for k < len(src) {
		switch src[k] {
		case ' ', '\t':
			k += 1
		case '#':
			p.pos = k
			comment(p) or_return
			k = p.pos
		case '\n':
			if !newlines {
				p.pos = k
				return true
			}
			p.pos = k
			root_heads(p)
			k += 1
			p.inline_ok = false
		case '\r':
			if !newlines {
				p.pos = k
				return true
			}
			if k + 1 >= len(src) || src[k + 1] != '\n' {
				p.pos = k
				return fault(p, k, .Bad_Char, .Lone_Cr)
			}
			p.pos = k
			root_heads(p)
			k += 2
			p.inline_ok = false
		case:
			p.pos = k
			return true
		}
	}
	p.pos = k
	return true
}

// Takes the comment whose `#` is at `p.pos`: the inline comment of the value that ended on its line, else one that
// waits for the node that follows.
@(private)
comment :: #force_no_inline proc(p: ^Parser) -> bool #no_bounds_check {
	end, v := scan_comment(p.src, p.pos)
	if v != 0 {
		p.fail = v
		return false
	}
	c := Comment{u64(p.pos), u32(end - p.pos)}
	if p.inline_ok && p.last != NIL {
		p.tree.inlines += 1
		if !reserve_notes(&p.tree) {
			return no_memory(p)
		}
		notes_for(&p.tree, p.last).inline = c
	} else if !push_comment(&p.tree, c) {
		return no_memory(p)
	}
	p.pos = end
	return true
}

// Gives the comments no node has taken to the root when no statement came before them and the line that ends at
// `p.pos` is blank: the text's head comment runs to its last blank line before the first statement.
@(private)
root_heads :: #force_inline proc(p: ^Parser) {
	if len(p.tree.nodes) == 1 && p.pending != u32(len(p.tree.comments)) {
		root_heads_of_blank_line(p)
	}
}

@(private)
root_heads_of_blank_line :: #force_no_inline proc(p: ^Parser) #no_bounds_check {
	i := p.pos
	for i > 0 && (p.src[i - 1] == ' ' || p.src[i - 1] == '\t') {
		i -= 1
	}
	if i > 0 && p.src[i - 1] == '\n' {
		root := notes_for(&p.tree, 0)
		root.head, root.heads = 0, u32(len(p.tree.comments))
		p.pending = root.heads
	}
}

// Judges the end of a statement: a comment, then a line end or the text's end.
@(private)
end_of_line :: proc(p: ^Parser) -> bool #no_bounds_check {
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

@(private)
bare_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return BARE_BYTES[b] != 0
}

@(private, rodata)
BARE_BYTES := [256]u8 {
	'a' ..= 'z' = 1,
	'A' ..= 'Z' = 1,
	'0' ..= '9' = 1,
	'_' = 1,
	'-' = 1,
}

// Reads one key at the position. A quoted key is a basic or literal string on one line, whose token's span leaves its
// quotes out.
@(private)
simple_key :: proc(p: ^Parser) -> (part: Part, ok: bool) #no_bounds_check {
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
		if u64(end - lo) > u64(max(u32)) {
			return {}, fault(p, lo, .Too_Wide, .None)
		}
		p.pos = end
		return name_part(p, tape.Token{u64(lo), u32(end - lo), .String, .Key, 0}, string(src[lo:end]))
	case c == '"' || c == '\'':
		return quoted_key(p, c)
	}
	return {}, fault(p, lo, .Bad_Char, .Expected_Key)
}

@(private)
quoted_key :: #force_no_inline proc(p: ^Parser, c: u8) -> (part: Part, ok: bool) #no_bounds_check {
	src := p.src
	lo := p.pos
	end: int
	escaped: bool
	v: Verdict
	if c == '"' {
		end, escaped, v = scan_string(src, lo, p.v11, false)
	} else {
		end, escaped, v = scan_string(src, lo, p.v11, true)
	}
	if v != 0 {
		p.fail = v
		return {}, false
	}
	p.pos = end
	if u64(end - lo - 2) > u64(max(u32)) {
		return {}, fault(p, lo, .Too_Wide, .None)
	}
	tok := tape.Token{u64(lo + 1), u32(end - lo - 2), .String, .Key, string_spelling(.Basic if c == '"' else .Literal, escaped)}
	if !escaped {
		return name_part(p, tok, string(src[lo + 1:end - 1]))
	}
	buf, err := runtime.arena_alloc(&p.tree.names, uint(max(end - lo - 2, 1)), 1)
	if err != nil {
		return {}, no_memory(p)
	}
	text, _ := text_decoded(src, tok, buf, nil)
	return Part{tok, text}, true
}

// The key part of token `tok` named `name`, a slice of the text, which the part holds a copy of when the text is read
// in pieces.
@(private)
name_part :: #force_inline proc(p: ^Parser, tok: tape.Token, name: string) -> (part: Part, ok: bool) {
	if !p.own {
		return Part{tok, name}, true
	}
	return name_copy(p, tok, name)
}

@(private)
name_copy :: #force_no_inline proc(p: ^Parser, tok: tape.Token, name: string) -> (part: Part, ok: bool) #no_bounds_check {
	buf, err := runtime.arena_alloc(&p.tree.names, uint(max(len(name), 1)), 1)
	if err != nil {
		return {}, no_memory(p)
	}
	copy(buf, name)
	return Part{tok, string(buf[:len(name)])}, true
}

// The first byte of key part `part`, its opening quote for a quoted key, where a fault of the key is.
@(private)
part_at :: #force_inline proc "contextless" (part: Part) -> int {
	return int(part.tok.lo) - int(part.tok.spelling & tape.SPELLING_QUOTED != 0)
}

// Reads a dotted key into `p.parts`, from its first byte: the caller has passed the white space before it.
@(private)
key_path :: proc(p: ^Parser) -> bool #no_bounds_check {
	clear(&p.parts)
	for {
		part := simple_key(p) or_return
		if _, err := append(&p.parts, part); err != nil {
			return no_memory(p)
		}
		skip_ws(p)
		if p.pos < len(p.src) && p.src[p.pos] == '.' {
			p.pos += 1
			skip_ws(p)
			continue
		}
		return true
	}
}

// Reads `=` and the white space after it.
@(private)
equals :: proc(p: ^Parser) -> bool #no_bounds_check {
	if p.pos >= len(p.src) || p.src[p.pos] != '=' {
		return fault(p, p.pos, .Bad_Char, .Expected_Equals)
	}
	p.pos += 1
	skip_ws(p)
	return true
}

// Adds the member `p.parts` names to table `table`, a dotted key's tables on the way. Returns the new value slot. The
// comments above go to the first node the key made.
@(private)
add_member :: proc(p: ^Parser, table: u32) -> (slot: u32, ok: bool) #no_bounds_check {
	cur, first := table, NIL
	for i in 0 ..< len(p.parts) - 1 {
		id, created, r := dotted_step(&p.tree, cur, &p.parts[i], u64(part_at(p.parts[i + 1])))
		refused(p, r, part_at(p.parts[i])) or_return
		if created && first == NIL {
			first = id
		}
		cur = id
	}
	last := &p.parts[len(p.parts) - 1]
	id, r := leaf_key(&p.tree, cur, last)
	refused(p, r, part_at(last^)) or_return
	take_heads(p, first if first != NIL else id)
	return id, true
}

// Reads a `key = value` statement into the current table.
@(private)
key_value :: proc(p: ^Parser) -> bool #no_bounds_check {
	key_path(p) or_return
	equals(p) or_return
	slot := add_member(p, p.cur) or_return
	return value_tree(p, slot)
}

// Reads a `[header]` or `[[header]]` statement and makes its table current.
@(private)
header :: proc(p: ^Parser) -> bool #no_bounds_check {
	src := p.src
	start := p.pos
	p.pos += 1
	array := p.pos < len(src) && src[p.pos] == '['
	if array {
		p.pos += 1
	}
	skip_ws(p)
	key_path(p) or_return
	for _ in 0 ..< 1 + int(array) {
		if p.pos >= len(src) || src[p.pos] != ']' {
			return fault(p, p.pos, .Truncated if p.pos >= len(src) else .Bad_Char, .Expected_Close)
		}
		p.pos += 1
	}
	cur := u32(0)
	for i in 0 ..< len(p.parts) - 1 {
		id, r := header_step(&p.tree, cur, &p.parts[i], u64(part_at(p.parts[i + 1])))
		refused(p, r, part_at(p.parts[i])) or_return
		cur = id
	}
	last := &p.parts[len(p.parts) - 1]
	id: u32
	r: Tree_Refusal
	heads := true
	if array {
		id, r = array_leaf(&p.tree, cur, last, u64(start), u64(p.pos))
	} else {
		id, heads, r = header_leaf(&p.tree, cur, last, u64(p.pos))
	}
	refused(p, r, part_at(last^)) or_return
	// The comments above a header that defines a table whose key a walk already gave go to the next node made.
	if heads {
		take_heads(p, id)
	}
	p.cur, p.last, p.inline_ok = id, id, true
	return true
}

// Ends the innermost open array or inline table at its closing byte.
@(private)
close_top :: proc(p: ^Parser) #no_bounds_check {
	top := pop(&p.stack)
	if foots := u32(len(p.tree.comments)) - p.pending; foots > 0 {
		n := notes_for(&p.tree, top)
		n.foot, n.foots = p.pending, foots
	}
	p.pending = u32(len(p.tree.comments))
	n := &p.tree.nodes[top]
	n.value.n = u32(u64(p.pos) - n.value.lo)
	p.pos += 1
	p.last, p.inline_ok = top, true
}

// Reads the next member of the innermost open container, or closes it at its closing byte. Returns the new value slot,
// and `closed` when it closed.
@(private)
next_member :: proc(p: ^Parser, after_comma: bool) -> (slot: u32, closed: bool, ok: bool) #no_bounds_check {
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
		id, r := add_node(&p.tree, top, nil, {}, .Scalar, {})
		refused(p, r, p.pos) or_return
		take_heads(p, id)
		return id, false, true
	}
	key_path(p) or_return
	equals(p) or_return
	slot = add_member(p, top) or_return
	return slot, false, true
}

// Sets node `id`'s scalar token, whose bytes end at `end`, or fails on a token too long to hold.
@(private)
set_scalar :: proc "contextless" (p: ^Parser, id: u32, t: tape.Token, end: int) -> bool #no_bounds_check {
	p.tree.nodes[id].value = t
	p.pos = end
	if end < len(p.src) && !terminator(p.src[end]) {
		return fault(p, end, .Bad_Char, .After_Value)
	}
	return true
}

// Reads one value into node `id`. Returns true in `opened` when it opened an array or an inline table, which stays open
// on the stack.
@(private)
value :: proc(p: ^Parser, id: u32) -> (opened: bool, ok: bool) #no_bounds_check {
	src := p.src
	if p.pos >= len(src) {
		return false, fault(p, len(src), .Truncated, .Expected_Value)
	}
	lo := p.pos
	c := src[lo]
	switch c {
	case '"', '\'':
		end: int
		escaped: bool
		v: Verdict
		style: Style
		multi := lo + 2 < len(src) && src[lo + 1] == c && src[lo + 2] == c
		switch {
		case c == '"' && multi:
			end, escaped, v = scan_multiline(src, lo, false, p.v11)
			style = .Multiline
		case c == '"':
			end, escaped, v = scan_string(src, lo, p.v11, false)
			style = .Basic
		case multi:
			end, _, v = scan_multiline(src, lo, true, p.v11)
			style = .Multiline_Literal
		case:
			end, escaped, v = scan_string(src, lo, p.v11, true)
			style = .Literal
		}
		if v != 0 {
			p.fail = v
			return false, false
		}
		text_lo, text_hi := string_text(src, lo, end, multi)
		if u64(text_hi - text_lo) > u64(max(u32)) {
			return false, fault(p, lo, .Too_Wide, .None)
		}
		return false, set_scalar(p, id, {u64(text_lo), u32(text_hi - text_lo), .String, .Value, string_spelling(style, escaped)}, end)
	case '[', '{':
		n := &p.tree.nodes[id]
		if n.depth + 1 > p.tree.max_depth {
			p.fail = hook.walk_result(u64(lo), hook.WALK_TOO_DEEP)
			return false, false
		}
		n.value = tape.Token{lo = u64(lo), kind = .Array if c == '[' else .Object, spelling = STYLE_INLINE}
		n.kind = .Array if c == '[' else .Table
		n.flags = {} if c == '[' else {.Inline}
		p.tree.deepest = max(p.tree.deepest, n.depth)
		p.pos += 1
		p.inline_ok = false
		if _, err := append(&p.stack, id); err != nil {
			return false, no_memory(p)
		}
		return true, true
	case 't', 'f':
		word := "true" if c == 't' else "false"
		if lo + len(word) > len(src) || string(src[lo:lo + len(word)]) != word {
			return false, fault(p, lo, .Bad_Char, .Expected_Value)
		}
		return false, set_scalar(p, id, {u64(lo), u32(len(word)), .True if c == 't' else .False, .Value, 0}, lo + len(word))
	case '+', '-', '0' ..= '9', 'i', 'n':
		if datetime_starts(src, lo) {
			end, kind, v := scan_datetime(src, lo, p.v11)
			if v != 0 {
				p.fail = v
				return false, false
			}
			return false, set_scalar(p, id, {u64(lo), u32(end - lo), .String, .Value, date_spelling(kind)}, end)
		}
		end, spelling, v := scan_number(src, lo)
		if v != 0 {
			p.fail = v
			return false, false
		}
		if u64(end - lo) > u64(max(u32)) {
			return false, fault(p, lo, .Too_Wide, .None)
		}
		return false, set_scalar(p, id, {u64(lo), u32(end - lo), .Number, .Value, spelling}, end)
	}
	return false, fault(p, lo, .Bad_Char, .Expected_Value)
}

// Reads the value of node `id` and the arrays and inline tables in it.
@(private)
value_tree :: proc(p: ^Parser, id: u32) -> bool #no_bounds_check {
	base := len(p.stack)
	cur := id
	opened := false
	for {
		if !opened {
			is_open := value(p, cur) or_return
			if !is_open {
				p.last, p.inline_ok = cur, true
			}
			opened = is_open
		}
		if opened {
			slot, closed := next_member(p, false) or_return
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
			slot, closed := next_member(p, true) or_return
			if !closed {
				cur = slot
				break
			}
		}
	}
}

// The first byte of the text from `lo`, past one byte order mark there.
@(private)
text_start :: #force_inline proc "contextless" (src: []u8, lo: int) -> int {
	if lo + 3 <= len(src) && src[lo] == 0xef && src[lo + 1] == 0xbb && src[lo + 2] == 0xbf {
		return lo + 3
	}
	return lo
}

// Reads the whole text into `p.tree`. Returns false with `p.fail` set at the first fault.
@(private)
parse_rest :: proc(p: ^Parser) -> bool {
	for !p.done {
		statement(p) or_return
	}
	return true
}

// Reads the next statement into `p.tree`, or sets `p.done` at the text's end. Every node a statement makes is whole
// once it returns, but for the tables a later header or dotted key can still add to.
@(private)
statement :: proc(p: ^Parser) -> bool #no_bounds_check {
	blanks(p, true) or_return
	if p.pos >= len(p.src) {
		// The comments past the last member end the table open at the text's end, the root when no header opened one.
		if foots := u32(len(p.tree.comments)) - p.pending; foots > 0 {
			last := notes_for(&p.tree, p.cur)
			last.foot, last.foots = p.pending, foots
		}
		p.pending = u32(len(p.tree.comments))
		p.done = true
		return true
	}
	if p.src[p.pos] == '[' {
		header(p) or_return
	} else {
		key_value(p) or_return
	}
	return end_of_line(p)
}
