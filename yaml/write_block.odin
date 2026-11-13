package yaml

// The block layout of a YAML text written in one pass, by the token write and by `marshal`. The writer keeps a column
// and a count per open collection. Where a line break and a dash or a key go is settled when the item arrives, and an
// empty collection is `{}` or `[]` when it closes.

import core "../core"
import write "../core/write"

// How a collection was reached, which says where its first item stands.
@(private)
Reach :: enum u8 {
	Root, // the document: column 0
	Key, // after `key:`: the first item is on the next line
	Dash, // after `- `: the first item is on the same line
}

@(private)
Level :: struct {
	object: bool,
	keyed:  bool, // a key is written and its value is owed
	reach:  Reach,
	col:    i32, // the column of the items
	n:      i32, // the items begun
}

@(private)
Block_Writer :: struct {
	out:      ^write.Out,
	step:     int, // the spaces of one level under a key
	ascii:    bool,
	ended:    bool, // the last byte written is a line end
	key_next: bool, // the next scalar is a key
	top:      int,
	levels:   [core.MAX_DEPTH]Level,
}

@(private)
block_new :: proc(out: ^write.Out, opts: core.Write_Options) -> ^Block_Writer {
	b := new(Block_Writer)
	b.out, b.ascii = out, opts.ascii
	b.step = int(opts.indent) if opts.indent > 0 else 2
	return b
}

// Writes what goes before the next item of the open collection and returns the column a literal block under it takes.
// An item is a key of a mapping, the value of a key, a dash's element or the root.
@(private)
block_lead :: proc(b: ^Block_Writer, container: bool) -> (literal_at: int) {
	if b.top == 0 {
		return b.step
	}
	l := &b.levels[b.top - 1]
	if l.object && l.keyed {
		l.keyed = false
		if !container {
			write.put_byte(b.out, ' ')
		}
		b.ended = false
		return int(l.col) + b.step
	}
	switch {
	case l.n > 0:
		if !b.ended {
			write.put_byte(b.out, '\n')
		}
		write.put_run(b.out, int(l.col), ' ')
	case l.reach == .Key:
		write.put_byte(b.out, '\n')
		write.put_run(b.out, int(l.col), ' ')
	}
	l.n += 1
	b.ended = false
	if l.object {
		return int(l.col) + b.step
	}
	write.put_text(b.out, "- ")
	return int(l.col) + 2
}

// Opens a mapping or sequence as the next item.
@(private)
block_open :: proc(b: ^Block_Writer, object: bool) -> core.Typed_Error_Kind {
	if b.top == core.MAX_DEPTH {
		return .Too_Deep
	}
	reach, col := Reach.Root, i32(0)
	if b.top > 0 {
		parent := b.levels[b.top - 1]
		reach, col = .Key, parent.col + i32(b.step)
		if !parent.object {
			reach, col = .Dash, parent.col + 2
		}
	}
	block_lead(b, true)
	b.levels[b.top] = {object = object, reach = reach, col = col}
	b.top += 1
	return .None
}

// Closes the open collection, which is `{}` or `[]` when it holds nothing.
@(private)
block_close :: proc(b: ^Block_Writer) {
	b.top -= 1
	l := b.levels[b.top]
	if l.n == 0 {
		if l.reach == .Key {
			write.put_byte(b.out, ' ')
		}
		write.put_text(b.out, "{}" if l.object else "[]")
		b.ended = false
	}
	block_end_root(b)
}

// Ends the text's last line when the root value is whole.
@(private)
block_end_root :: proc(b: ^Block_Writer) {
	if b.top == 0 && !b.ended {
		write.put_byte(b.out, '\n')
		b.ended = true
	}
}

// Writes the key `text`, which is the spelling of a key, and its colon.
@(private)
block_key :: proc(b: ^Block_Writer, name: string) -> core.Typed_Error_Kind {
	l := &b.levels[b.top - 1]
	block_lead(b, false)
	explicit := len(name) > KEY_MAX
	if explicit {
		write.put_text(b.out, "? ")
	}
	shape, kind := shape_of(name, {key = true, ascii = b.ascii})
	if kind != .None {
		return kind
	}
	if shape == .Plain && explicit {
		shape = .Single
	}
	put_scalar(b.out, name, shape, b.ascii)
	if explicit {
		write.put_byte(b.out, '\n')
		write.put_run(b.out, int(l.col), ' ')
	}
	write.put_byte(b.out, ':')
	l.keyed = true
	return .None
}

// Writes the string `s` as the next item, as a plain, quoted or literal scalar.
@(private)
block_string :: proc(b: ^Block_Writer, s: string) -> core.Typed_Error_Kind {
	at := block_lead(b, false)
	shape, kind := shape_of(s, {block = true, ascii = b.ascii})
	if kind != .None {
		return kind
	}
	if shape == .Literal {
		put_literal(b.out, s, at)
		b.ended = true
		block_end_root(b)
		return .None
	}
	put_scalar(b.out, s, shape, b.ascii)
	block_end_root(b)
	return .None
}

// Writes `text`, the spelling of a number, a word or a tagged scalar, as the next item.
@(private)
block_raw :: proc(b: ^Block_Writer, text: string) {
	block_lead(b, false)
	write.put_text(b.out, text)
	block_end_root(b)
}

// The steps a format with its own layout is called for, see `write.Token_Spelling.layout`.
@(private)
layout_step :: proc(t: ^write.Tokens, step: write.Layout_Step) -> core.Typed_Error_Kind {
	b := (^Block_Writer)(t.state)
	switch step {
	case .Open_Object:
		return block_open(b, true)
	case .Open_Array:
		return block_open(b, false)
	case .Close:
		block_close(b)
	case .Key:
		b.key_next = true
	}
	return .None
}

@(private)
block_free :: proc(b: ^Block_Writer) {
	free(b)
}

// Writes flow text that a typed write made, one line of a value with quoted keys and spelled scalars, as block style. The
// scalars are copied as they stand. A scalar that is a key is the one before a colon.
@(private)
block_from_flow :: proc(b: ^Block_Writer, text: string) -> core.Typed_Error_Kind {
	at := 0
	for at < len(text) {
		switch text[at] {
		case '{':
			block_open(b, true) or_return
			at += 1
		case '[':
			block_open(b, false) or_return
			at += 1
		case '}', ']':
			block_close(b)
			at += 1
		case ',', ' ', '\n':
			at += 1
		case:
			end := scalar_end(text, at)
			word := text[at:end]
			at = end
			if b.top > 0 && b.levels[b.top - 1].object && !b.levels[b.top - 1].keyed {
				block_lead(b, false)
				write.put_text(b.out, word)
				write.put_byte(b.out, ':')
				b.levels[b.top - 1].keyed = true
				at += 1
				continue
			}
			block_raw(b, word)
		}
	}
	return b.out.err
}

// Writes the flow text of a typed write, which has a line a member, as one line: a line end after a comma is a space and
// any other is dropped.
@(private)
flow_from_lines :: proc(out: ^write.Out, text: string) {
	run := 0
	for i in 0 ..< len(text) {
		if text[i] != '\n' {
			continue
		}
		write.put_text(out, text[run:i])
		if i > 0 && text[i - 1] == ',' {
			write.put_byte(out, ' ')
		}
		run = i + 1
	}
	write.put_text(out, text[run:])
}

// The end of the flow scalar that starts at `from`: a quoted scalar ends at its closing quote, a plain one before a
// comma, a closing bracket or a colon and a space.
@(private)
scalar_end :: proc(text: string, from: int) -> int {
	at := from
	switch text[at] {
	case '"':
		at += 1
		for at < len(text) && text[at] != '"' {
			at += 2 if text[at] == '\\' else 1
		}
		return min(at + 1, len(text))
	case '\'':
		at += 1
		for at < len(text) {
			if text[at] == '\'' {
				if at + 1 < len(text) && text[at + 1] == '\'' {
					at += 2
					continue
				}
				break
			}
			at += 1
		}
		return min(at + 1, len(text))
	}
	for at < len(text) {
		switch text[at] {
		case ',', ']', '}', '\n':
			return at
		case ':':
			if at + 1 >= len(text) || text[at + 1] == ' ' {
				return at
			}
		}
		at += 1
	}
	return at
}
