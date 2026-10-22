package main

// --stream-errors on a text that does not parse: jq's streaming parser (jv_parse.c, `stream_token` and its scanner)
// run over the faulty text, which gives the events of everything before the fault and then the error as an event,
// `[message, path]`, in jq's words and count of lines and columns. The library validates a text whole and so cannot
// say which events precede a fault. This walk is reached only for a text it has refused, so a valid stream never pays
// for it. Plain --stream keeps the library's report (`text_fault`).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "jq"

@(private = "file")
Last_Seen :: enum u8 {
	None,
	Open_Array,
	Open_Object,
	Colon,
	Comma,
	Value,
}

@(private = "file")
Lexing :: enum u8 {
	Normal,
	String,
	Escape,
}

@(private = "file")
Parser :: struct {
	src:          []byte,
	events:       [dynamic]jq.Value, // the events made so far, the error's last
	staged:       [dynamic]jq.Value, // those of the byte being scanned, dropped if jq refuses it
	path:         [dynamic]jq.Value, // an array's index, an object's key once known, else null
	last:         Last_Seen,
	next:         jq.Value, // the value read last, held until a separator shows it done
	has_next:     bool,
	token_start:  int, // the literal being read, if token_open
	token_open:   bool,
	string_start: int, // the opening quote of the string being read
	lexing:       Lexing,
	line, column: int,
	line0, column0: int, // where src begins
	refusal:      Place, // where the refusal being reported stands, if not at the byte scanned
}

@(private = "file")
Place :: struct {
	line, column: int,
}

// The events of `src`, a faulty text that starts at `line` and `column` in jq's count, as jq's parser gives them,
// each error as its own event. `fault` is the byte index where jq read last, `errored` whether it found one, and
// `line` and `column` where it counts to by then. A text ends at its first fault, and the stream goes on from the
// next line. Under --seq `src` is one record, `rs_follows` tells whether a separator ends it, and after a fault jq's
// parser, which means to wait for the separator, starts afresh on the next byte. `reset_each` is a parser jq starts
// afresh at every call (a cut byte order mark leaves it so under --seq). `late_error` is an error at the end that jq
// gives after the event the last byte left pending, which -s therefore keeps out of its array. The events are the
// heap's, to outlive the call.
stream_fault :: proc(src: []byte, line, column: int, seq, rs_follows, reset_each: bool) -> (events: [dynamic]jq.Value, fault: int, errored: bool, at_line, at_column: int, late_error: bool) {
	context.allocator = runtime.heap_allocator()
	p := Parser {
		src    = src,
		line    = line,
		column  = column,
		line0   = line,
		column0 = column,
	}
	defer delete(p.staged)
	defer delete(p.path)
	for fault < len(src) {
		clear(&p.staged)
		msg := scan(&p, fault)
		if msg == "" {
			late_error = len(p.staged) > 1
			if reset_each && len(p.staged) > 0 { // jq gives one event a call, and starts the next call afresh
				append(&p.events, p.staged[0])
				reset(&p)
			} else {
				append(&p.events, ..p.staged[:])
			}
			fault += 1
			continue
		}
		errored, late_error = true, false
		at := Place{p.line, p.column} if p.refusal.line == 0 else p.refusal
		p.refusal = {}
		fail(&p, fmt.aprintf("%s at line %d, column %d%s", msg, at.line, at.column, " (need RS to resync)" if seq else ""))
		if !seq {
			return p.events, fault, true, p.line, p.column, false
		}
		fault += 1
	}
	clear(&p.staged)
	if rs_follows {
		if msg := at_separator(&p, fault); msg != "" {
			fail(&p, fmt.aprintf("%s at line %d, column %d", msg, p.line, p.column))
			errored = true
		}
		return p.events, fault, errored, p.line, p.column, false
	}
	if reset_each { // the call that finds the end begins afresh, with nothing held
		return p.events, fault, errored, p.line, p.column, false
	}
	msg := "Unfinished string" if p.lexing != .Normal else check_literal(&p, fault)
	if msg == "" && p.lexing == .Normal && len(p.path) != 0 {
		msg = "Unfinished JSON term"
	}
	if msg != "" {
		fail(&p, fmt.aprintf("%s at EOF at line %d, column %d", msg, p.line, p.column))
		return p.events, fault, true, p.line, p.column, late_error
	}
	if p.has_next { // a literal the end of the text ends
		append(&p.events, event(&p, p.next))
	}
	return p.events, fault, errored, p.line, p.column, false
}

// A record's separator, scanned by jq as a byte of its own: what it refuses, or the value it ends.
@(private = "file")
at_separator :: proc(p: ^Parser, at: int) -> string {
	p.column += 1
	if p.lexing != .Normal { // jq reads what a string holds so far as a literal
		p.token_start, p.token_open = p.string_start + 1, p.string_start + 1 < at
	}
	_, is_string := p.next.(string)
	if len(p.path) > 0 || p.has_next && !is_string {
		_, is_number := p.next.(jq.Number)
		if check_literal(p, at) == "" && len(p.path) == 0 && is_number {
			return jq.TRUNCATED_NUMBER_NOTE
		}
		return "Truncated value"
	}
	if msg := check_literal(p, at); msg != "" {
		return msg
	}
	if p.lexing == .Normal && len(p.path) == 0 && p.has_next {
		append(&p.events, event(p, p.next))
	}
	return ""
}

// The error as an event, `[message, path]`, and the parser afresh, as jq's `parser_reset` leaves it.
@(private = "file")
fail :: proc(p: ^Parser, text: string) {
	ev := jq.new_array(2)
	append(&ev.items, text, path_copy(p))
	append(&p.events, ev)
	reset(p)
}

// jq's `parser_reset`.
@(private = "file")
reset :: proc(p: ^Parser) {
	clear(&p.path)
	p.last, p.next, p.has_next, p.token_open, p.lexing = .None, nil, false, false, .Normal
}

@(private = "file")
path_copy :: proc(p: ^Parser) -> ^jq.Array {
	a := jq.new_array(len(p.path))
	append(&a.items, ..p.path[:])
	return a
}

// `[path, leaf]`.
@(private = "file")
event :: proc(p: ^Parser, leaf: jq.Value) -> jq.Value {
	ev := jq.new_array(2)
	append(&ev.items, path_copy(p), leaf)
	return ev
}

// `[path]`, after a container's last member.
@(private = "file")
closing :: proc(p: ^Parser) -> jq.Value {
	ev := jq.new_array(1)
	append(&ev.items, path_copy(p))
	return ev
}

@(private = "file")
Class :: enum u8 {
	Literal,
	Space,
	Structure,
	Quote,
}

@(private = "file")
classify :: proc(c: byte) -> Class {
	switch c {
	case '"':
		return .Quote
	case '[', ',', ']', '{', ':', '}':
		return .Structure
	}
	return .Literal if is_literal_byte(c) else .Space
}

// jq's scan for the byte at src[i]: its reason to refuse it, if any.
@(private = "file")
scan :: proc(p: ^Parser, i: int) -> string {
	ch := p.src[i]
	p.column += 1
	if ch == '\n' {
		p.line += 1
		p.column = 0
	}
	if p.lexing != .Normal {
		if ch == '"' && p.lexing == .String {
			if msg := found_string(p, i); msg != "" {
				return msg
			}
			p.lexing = .Normal
			emit_scalar(p)
		} else {
			p.lexing = .Escape if ch == '\\' && p.lexing == .String else .String
		}
		return ""
	}
	class := classify(ch)
	if class != .Literal {
		if msg := check_literal(p, i); msg != "" {
			return msg
		}
		emit_scalar(p)
	}
	switch class {
	case .Literal:
		if !p.token_open {
			p.token_start, p.token_open = i, true
		}
	case .Space:
	case .Quote:
		p.lexing, p.string_start = .String, i
	case .Structure:
		if msg := stream_token(p, ch); msg != "" {
			return msg
		}
	}
	emit_scalar(p)
	return ""
}

// A top-level scalar, once a separator shows it done, is an event of its own.
@(private = "file")
emit_scalar :: proc(p: ^Parser) {
	if len(p.path) == 0 && p.has_next {
		append(&p.staged, event(p, p.next))
		p.next, p.has_next = nil, false
	}
}

// The value just read: refused where another is held, or follows a member's value with no separator.
@(private = "file")
value :: proc(p: ^Parser, v: jq.Value) -> string {
	if p.has_next || p.last == .Value {
		return "Expected separator between values"
	}
	p.last = .Value if len(p.path) > 0 else .None
	p.next, p.has_next = v, true
	return ""
}

// The literal read so far, which a separator or the end ends: true, false, null or a number.
@(private = "file")
check_literal :: proc(p: ^Parser, end: int) -> string {
	if !p.token_open {
		return ""
	}
	tok := string(p.src[p.token_start:end])
	pattern: string
	v: jq.Value
	switch tok[0] {
	case 't':
		pattern, v = "true", true
	case 'f':
		pattern, v = "false", false
	case '\'':
		return "Invalid string literal; expected \", but got '"
	case 'n':
		if len(tok) > 1 && tok[1] == 'u' {
			pattern = "null"
		}
	}
	if pattern != "" {
		if tok != pattern {
			return "Invalid literal"
		}
	} else {
		n, ok := jq.read_number(tok)
		if !ok {
			return "Invalid numeric literal"
		}
		v = n
		if x, is_number := n.(jq.Number); is_number {
			v = jq.Number{f = x.f, lit = strings.clone(x.lit)}
		}
	}
	if msg := value(p, v); msg != "" {
		return msg
	}
	p.token_open = false
	return ""
}

// The string between src[string_start] and src[i], quotes apart: jq's reason to refuse it, else it is the value read.
@(private = "file")
found_string :: proc(p: ^Parser, i: int) -> string {
	out := strings.builder_make()
	stury_only_at := -1
	if msg := jq.decode_string(&out, string(p.src[p.string_start + 1:i]), &stury_only_at); msg != "" {
		if stury_only_at >= 0 { // a refusal of stury's own, put where the library puts it: at the backslash
			p.refusal = place_of(p, p.string_start + 1 + stury_only_at)
		}
		return msg
	}
	return value(p, jq.valid_utf8(strings.to_string(out)))
}

// jq's line and column of src[at].
@(private = "file")
place_of :: proc(p: ^Parser, at: int) -> Place {
	line, column := p.line0, p.column0
	jq.advance(&line, &column, p.src[:at + 1])
	return {line, column}
}

@(private = "file")
path_is_index :: proc(p: ^Parser) -> bool {
	_, number := p.path[len(p.path) - 1].(jq.Number)
	return number
}

@(private = "file")
path_is_key :: proc(p: ^Parser) -> bool {
	_, key := p.path[len(p.path) - 1].(string)
	return key
}

// jq's stream_token: a structural byte, which opens or closes a container, separates members, or is refused.
@(private = "file")
stream_token :: proc(p: ^Parser, ch: byte) -> string {
	top := len(p.path) - 1
	switch ch {
	case '[', '{':
		open := ch == '['
		if open && p.has_next || !open && p.last == .Value {
			return "Expected a separator between values"
		}
		if p.last == .Open_Object {
			return fmt.aprintf("%s%c'", "Expected string key after '{', not '", ch)
		}
		if p.last == .Comma && !path_is_index(p) {
			return fmt.aprintf("Expected string key after ',' in object, not '%c'", ch)
		}
		if open {
			append(&p.path, jq.num(0))
			p.last = .Open_Array
		} else {
			append(&p.path, nil)
			p.last = .Open_Object
		}
	case ':':
		if len(p.path) == 0 || path_is_index(p) {
			return "':' not as part of an object"
		}
		if !p.has_next || p.last == .None {
			return "Expected string key before ':'"
		}
		key, is_key := p.next.(string)
		if !is_key {
			return "Object keys must be strings"
		}
		if p.last != .Value {
			return "':' should follow a key"
		}
		p.last = .Colon
		p.path[top] = key
		p.next, p.has_next = nil, false
	case ',':
		if p.last != .Value {
			return "Expected value before ','"
		}
		if len(p.path) == 0 {
			return "',' not as part of an object or array"
		}
		if !path_is_index(p) && !path_is_key(p) {
			return "Objects must consist of key:value pairs"
		}
		if p.has_next {
			append(&p.staged, event(p, p.next))
			p.next, p.has_next = nil, false
		}
		if index, is_index := p.path[top].(jq.Number); is_index {
			p.path[top] = jq.num(index.f + 1)
		} else {
			p.path[top] = nil // ready for another key
		}
		p.last = .Comma
	case ']':
		if len(p.path) == 0 {
			return "Unmatched ']' at the top-level"
		}
		if p.last == .Comma {
			return "Expected another array element"
		}
		if !path_is_index(p) {
			return "Unmatched ']' in the middle of an object"
		}
		close_container(p, jq.new_array())
	case '}':
		if len(p.path) == 0 {
			return "Unmatched '}' at the top-level"
		}
		if p.last == .Comma {
			return "Expected another key:value pair"
		}
		if path_is_index(p) {
			return "Unmatched '}' in the middle of an array"
		}
		switch {
		case p.has_next && !path_is_key(p):
			return "Objects must consist of key:value pairs"
		case !p.has_next && p.last == .Colon:
			return "Missing value in key:value pair"
		case !p.has_next && p.last != .Value && p.last != .Open_Object:
			return "Unmatched '}'"
		}
		close_container(p, jq.new_object())
	}
	return ""
}

// A container's end: the event of the member held, if any, then `[path]` for the container. A container with no
// member is a leaf, `[path, [] or {}]`, once it is popped.
@(private = "file")
close_container :: proc(p: ^Parser, empty: jq.Value) {
	was_empty := p.last == .Open_Array || p.last == .Open_Object
	if p.has_next {
		append(&p.staged, event(p, p.next))
	}
	if !was_empty {
		append(&p.staged, closing(p))
	}
	p.next, p.has_next = nil, false
	pop(&p.path)
	if was_empty {
		append(&p.staged, event(p, empty))
	}
	p.last = .None if len(p.path) == 0 else .Value
}
