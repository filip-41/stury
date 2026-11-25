package write

import "base:runtime"
import "stury:lib/core/tape"

// The order a caller writes values one token at a time in, which every format's token writer checks the same way: a
// container opens, holds its members' keys with a value after each, or its elements, and closes, and the text holds
// one root value, or under a framing any number of them. A format gives the spelling of each token and lays out what
// `Place` says stands before it.

// The tokens of a value, as `tape.Token_Kind` names them.
Token_Kind :: tape.Token_Kind

// The levels a sequence holds in itself. Past them its stack comes from the writer's allocator.
TOKEN_LEVELS :: 64

@(private)
LEVEL_OBJECT :: 1
@(private)
LEVEL_FILLED :: 2 // the container holds a member or element
@(private)
LEVEL_KEY :: 4 // an object's key waits for its value

// What the layout of a token depends on.
Place :: struct {
	depth:  int, // containers open around it, a close's own not counted
	first:  bool, // the first member or element of its container
	object: bool, // inside an object, and for a close the container it closes is one
	value:  bool, // the value of the key before it
	root:   bool, // at the top level
	empty:  bool, // a close of a container that holds nothing
}

// The state of a token sequence. It points into itself, so it is not copied once started.
Sequence :: struct {
	levels:    [^]u8,
	held:      int,
	depth:     int,
	roots:     int,
	taken:     int, // the tokens taken, which a refusal names
	max_depth: int,
	framed:    bool, // any number of root values
	allocator: runtime.Allocator,
	inline:    [TOKEN_LEVELS]u8,
}

// Starts `s`, which is to hold at most `max_depth` open containers, `tape.DEFAULT_DEPTH` for 0.
sequence_start :: proc(s: ^Sequence, framed: bool, max_depth: int, allocator: runtime.Allocator) {
	s^ = {framed = framed, max_depth = max_depth if max_depth > 0 else tape.DEFAULT_DEPTH, allocator = allocator, held = TOKEN_LEVELS}
	s.levels = &s.inline[0]
}

// Frees what `s` grew past its own levels.
sequence_drop :: proc(s: ^Sequence) {
	free_stack(s.levels, s.held, TOKEN_LEVELS, s.allocator)
	s.levels, s.held = nil, 0
}

// Whether the tokens so far are a whole text: no container open and a root written.
sequence_done :: proc "contextless" (s: ^Sequence) -> bool {
	return s.depth == 0 && s.roots > 0
}

// Takes token `kind`. A token this place cannot hold is `Refused{index, .Malformed}` and leaves `s` as it was.
sequence_take :: proc(s: ^Sequence, kind: Token_Kind) -> (p: Place, err: Error) #no_bounds_check {
	malformed := Refused{tape.Node_Index(s.taken), .Malformed}
	p = {depth = s.depth, root = s.depth == 0}
	top: ^u8
	if s.depth > 0 {
		top = &s.levels[s.depth - 1]
		p.object, p.first = top^ & LEVEL_OBJECT != 0, top^ & LEVEL_FILLED == 0
	}
	switch kind {
	case .Close:
		if s.depth == 0 || top^ & LEVEL_KEY != 0 {
			return p, malformed
		}
		s.depth -= 1
		p = {depth = s.depth, root = s.depth == 0, empty = p.first, object = p.object}
		s.taken += 1
		return p, nil
	case .Key:
		if top == nil || !p.object || top^ & LEVEL_KEY != 0 {
			return p, malformed
		}
		top^ |= LEVEL_KEY
		s.taken += 1
		return p, nil
	case .Object, .Array, .String, .Number, .True, .False, .Null:
	}
	switch {
	case top == nil:
		if s.roots > 0 && !s.framed {
			return p, malformed
		}
	case p.object:
		if top^ & LEVEL_KEY == 0 {
			return p, malformed
		}
		p.value = true
	}
	opens := kind == .Object || kind == .Array
	if opens && s.depth >= s.max_depth {
		return p, malformed
	}
	if opens && s.depth == s.held && !grow_stack(&s.levels, &s.held, TOKEN_LEVELS, s.allocator, &err) {
		return p, err
	}
	if top != nil {
		top = &s.levels[s.depth - 1]
		top^ = top^ & ~u8(LEVEL_KEY) | LEVEL_FILLED
	} else {
		s.roots += 1
	}
	if opens {
		s.levels[s.depth] = LEVEL_OBJECT if kind == .Object else 0
		s.depth += 1
	}
	s.taken += 1
	return p, nil
}
