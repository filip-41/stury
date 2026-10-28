package main

// --stream on a text that does not parse: jq's streaming parser (jv_parse.c, `stream_token` and its scanner) run
// over the faulty text, which gives the events of everything before the fault and then, for --stream-errors, the
// error as an event, `[message, path]`, in jq's words and count of lines and columns. The library validates a text
// whole and so cannot say which events precede a fault. This walk is reached only for a text it has refused, so a
// valid stream never pays for it. Plain --stream ends the events with the library's report (`text_fault`).

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "jq"
import "message"

// An event of a faulty text and the byte of the text jq's parser reads to make it, which tells the line jq's reader is on.
Fault_Event :: struct {
	value: jq.Value,
	at:    int,
	error: bool, // `[message, path]`
	late:  bool, // an error at the end that jq gives after the event the last byte left pending, which -s therefore keeps out of its array
}

// jq's parser over a faulty text, run only as far as the events asked of it, so that what it holds is the size of the
// path, not of the text. Once `ended`, `at` is the byte where jq read last, `errored` whether it found a fault, and
// `line` and `column` where it counts to by then.
Fault_Walk :: struct {
	p:            Parser,
	at:           int,
	ended:        bool,
	errored:      bool,
	line, column: int,
	seq, rs_follows, reset_each, late: bool,
	given:        int, // p.events[:given] are given
	arenas:       [2]virtual.Arena, // what the parser makes, in arenas[gen]; the other takes its state over (`renew`)
	gen:          int,
	held:         uint, // what renew moved: the next renew waits until the arena holds twice as much
}

// Bytes past which the walk's arena is renewed, once every event made in it is given.
@(private = "file")
WALK_ARENA_RENEW :: 1 << 20

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
	events:       [dynamic]Fault_Event, // the events made and not yet given
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

// The walk of `src`, a faulty text that starts at `line` and `column` in jq's count, which gives jq's events of it,
// each error as its own event. A text ends at its first fault, and the stream goes on from the next line. Under --seq
// `src` is one record, `rs_follows` tells whether a separator ends it, and after a fault jq's parser, which means to
// wait for the separator, starts afresh on the next byte. `reset_each` is a parser jq starts afresh at every call (a
// cut byte order mark leaves it so under --seq). The walk is the heap's and lives for the run, made in `spare` when
// one is given: a walk that has ended, whose arrays and arenas' first blocks are kept.
fault_walk :: proc(src: []byte, line, column: int, seq, rs_follows, reset_each: bool, spare: ^Fault_Walk = nil) -> ^Fault_Walk {
	heap := runtime.heap_allocator()
	w := spare
	if w == nil {
		w = new(Fault_Walk, heap)
		w.p.events.allocator, w.p.staged.allocator, w.p.path.allocator = heap, heap, heap
	}
	clear(&w.p.events)
	clear(&w.p.staged)
	clear(&w.p.path)
	virtual.arena_free_all(&w.arenas[0])
	virtual.arena_free_all(&w.arenas[1])
	w^ = Fault_Walk {
		p = Parser {
			src = src,
			events = w.p.events,
			staged = w.p.staged,
			path = w.p.path,
			line = line,
			column = column,
			line0 = line,
			column0 = column,
		},
		seq = seq,
		rs_follows = rs_follows,
		reset_each = reset_each,
		arenas = w.arenas,
	}
	return w
}

// The next event, made in the context allocator, or false once the walk has ended.
fault_event :: proc(w: ^Fault_Walk) -> (ev: Fault_Event, ok: bool) {
	ev = fault_peek(w) or_return
	w.given += 1
	ev.value = jq.event_clone(ev.value)
	return ev, true
}

// The next event, as the walk holds it, without giving it.
fault_peek :: proc(w: ^Fault_Walk) -> (Fault_Event, bool) {
	for w.given == len(w.p.events) {
		if w.ended {
			return {}, false
		}
		clear(&w.p.events)
		w.given = 0
		if w.arenas[w.gen].total_used > max(WALK_ARENA_RENEW, 2 * w.held) {
			renew(w)
		}
		context.allocator = virtual.arena_allocator(&w.arenas[w.gen])
		step(w)
	}
	return w.p.events[w.given], true
}

// The parser's state, all the walk keeps between bytes, moved to the other arena, and this one emptied.
@(private = "file")
renew :: proc(w: ^Fault_Walk) {
	old := w.gen
	w.gen = 1 - old
	context.allocator = virtual.arena_allocator(&w.arenas[w.gen])
	for &s in w.p.path {
		s = jq.event_clone(s)
	}
	w.p.next = jq.event_clone(w.p.next)
	w.held = w.arenas[w.gen].total_used
	virtual.arena_free_all(&w.arenas[old])
}

// One byte of the text scanned, or once all are, its end; what events either makes go to `w.p.events`.
@(private = "file")
step :: proc(w: ^Fault_Walk) {
	p := &w.p
	defer if w.ended {
		w.line, w.column = p.line, p.column
	}
	if p.lexing == .String { // a string's other bytes only move the column
		j := w.at
		for j < len(p.src) && p.src[j] != '"' && p.src[j] != '\\' && p.src[j] != '\n' {
			j += 1
		}
		if j > w.at {
			p.column += j - w.at
			w.at, w.late = j, false
		}
	}
	if w.at < len(p.src) {
		clear(&p.staged)
		msg := scan(p, w.at)
		if msg == "" {
			w.late = len(p.staged) > 1
			if w.reset_each && len(p.staged) > 0 { // jq gives one event a call, and starts the next call afresh
				append(&p.events, Fault_Event{value = p.staged[0], at = w.at})
				reset(p)
			} else {
				for ev in p.staged {
					append(&p.events, Fault_Event{value = ev, at = w.at})
				}
			}
			w.at += 1
			return
		}
		w.errored, w.late = true, false
		at := Place{p.line, p.column} if p.refusal.line == 0 else p.refusal
		p.refusal = {}
		fail(p, message.build("%s at line %d, column %d%s", msg, at.line, at.column, " (need RS to resync)" if w.seq else ""), w.at)
		if w.seq {
			w.at += 1
		} else {
			w.ended = true
		}
		return
	}
	w.ended = true
	clear(&p.staged)
	switch {
	case w.rs_follows:
		if msg := at_separator(p, w.at); msg != "" {
			fail(p, message.build("%s at line %d, column %d", msg, p.line, p.column), w.at)
			w.errored = true
		}
	case w.reset_each: // the call that finds the end begins afresh, with nothing held
	case:
		msg := "Unfinished string" if p.lexing != .Normal else check_literal(p, w.at)
		if msg == "" && p.lexing == .Normal && len(p.path) != 0 {
			msg = "Unfinished JSON term"
		}
		if msg != "" {
			fail(p, message.build("%s at EOF at line %d, column %d", msg, p.line, p.column), w.at)
			p.events[len(p.events) - 1].late = w.late
			w.errored = true
		} else if p.has_next { // a literal the end of the text ends
			append(&p.events, Fault_Event{value = jq.event_of(path_copy(p), p.next), at = w.at})
		}
	}
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
		append(&p.events, Fault_Event{value = jq.event_of(path_copy(p), p.next), at = at})
	}
	return ""
}

// The error as an event, `[message, path]`, and the parser afresh, as jq's `parser_reset` leaves it.
@(private = "file")
fail :: proc(p: ^Parser, text: string, at: int) {
	ev := jq.new_array(2)
	append(&ev.items, text, path_copy(p))
	append(&p.events, Fault_Event{value = ev, at = at, error = true})
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
		append(&p.staged, jq.event_of(path_copy(p), p.next))
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
			return message.build("%s%c'", "Expected string key after '{', not '", ch)
		}
		if p.last == .Comma && !path_is_index(p) {
			return message.build("Expected string key after ',' in object, not '%c'", ch)
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
			append(&p.staged, jq.event_of(path_copy(p), p.next))
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
		append(&p.staged, jq.event_of(path_copy(p), p.next))
	}
	if !was_empty {
		append(&p.staged, jq.event_of(path_copy(p)))
	}
	p.next, p.has_next = nil, false
	pop(&p.path)
	if was_empty {
		append(&p.staged, jq.event_of(path_copy(p), empty))
	}
	p.last = .None if len(p.path) == 0 else .Value
}
