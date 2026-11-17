package yaml

// The block layout of a YAML text written in one pass, by the token write and by `marshal`. The writer keeps a column
// and a count per open collection. Where a line break and a dash or a key go is settled when the item arrives, and an
// empty collection is `{}` or `[]` when it closes.

import "core:slice"
import "core:strings"
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
	head:   int, // the output offset past its key's `:`, where an inline comment on it goes
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
	// The output offsets of the head of the block collection after a key closed last and of its end, which an inline
	// comment on it, coming before anything else is written, goes back to, and whether one is there.
	closed:   [2]int,
	noted:    bool,
	// The comments in the innermost open collection before its first item, which lead that item, or are the foot of
	// the collection when it closes empty.
	held:     [dynamic]string,
}

@(private)
block_new :: proc(out: ^write.Out, opts: core.Write_Options) -> ^Block_Writer {
	b := new(Block_Writer)
	b.out, b.ascii, b.ended = out, opts.ascii, true
	b.step = int(opts.indent) if opts.indent > 0 else 2
	return b
}

// Writes what goes before the next item of the open collection and returns the column a literal block under it takes.
// An item is a key of a mapping, the value of a key, a dash's element or the root.
@(private)
block_lead :: proc(b: ^Block_Writer, container: bool) -> (literal_at: int) {
	if b.top == 0 {
		b.ended = b.ended && container
		return b.step
	}
	l := &b.levels[b.top - 1]
	if len(b.held) > 0 && !l.keyed {
		block_put_held(b, l^)
	}
	if l.object && l.keyed {
		l.keyed = false
		if !container {
			write.put_byte(b.out, ' ')
		}
		b.ended = false
		return int(l.col) + b.step
	}
	if l.n > 0 || l.reach == .Key {
		if !b.ended {
			write.put_byte(b.out, '\n')
		}
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
	b.levels[b.top] = {object = object, reach = reach, col = col, head = b.out.flushed + b.out.cursor}
	b.top += 1
	return .None
}

// Closes the open collection, which is `{}` or `[]` when it holds nothing.
@(private)
block_close :: proc(b: ^Block_Writer) {
	b.top -= 1
	b.closed, b.noted = {}, false
	if l := b.levels[b.top]; l.n == 0 {
		block_empty(b, l)
	} else if l.reach == .Key {
		b.closed = {l.head, b.out.flushed + b.out.cursor}
	}
	block_end_root(b)
}

// Writes the empty collection `l` as `{}` or `[]`, with the held comments inside it on lines of their own, where they
// read back as its foot.
@(private)
block_empty :: proc(b: ^Block_Writer, l: Level) {
	if l.reach == .Key {
		write.put_byte(b.out, ' ')
	}
	if len(b.held) == 0 {
		write.put_text(b.out, "{}" if l.object else "[]")
	} else {
		write.put_text(b.out, "{\n" if l.object else "[\n")
		for text in b.held {
			write.put_run(b.out, int(l.col), ' ')
			write.put_comment(b.out, "#", text, true, int(l.col))
			write.put_byte(b.out, '\n')
		}
		write.put_run(b.out, int(l.col), ' ')
		write.put_byte(b.out, '}' if l.object else ']')
		block_drop_held(b)
	}
	b.ended = false
}

// Writes the held comments before the first item of `l`, at its column. After a dash the first item stands on the
// dash's line, so the comments do and the item goes to the next line.
@(private)
block_put_held :: proc(b: ^Block_Writer, l: Level) {
	for text in b.held {
		if l.reach == .Dash {
			write.put_comment(b.out, "#", text, true, int(l.col))
			write.put_byte(b.out, '\n')
			write.put_run(b.out, int(l.col), ' ')
			b.ended = false
			continue
		}
		if !b.ended {
			write.put_byte(b.out, '\n')
		}
		write.put_run(b.out, int(l.col), ' ')
		write.put_comment(b.out, "#", text, true, int(l.col))
		write.put_byte(b.out, '\n')
		b.ended = true
	}
	block_drop_held(b)
}

@(private)
block_drop_held :: proc(b: ^Block_Writer) {
	for text in b.held {
		delete(text)
	}
	clear(&b.held)
}

// Writes `text` as `#` lines of `role`: a lead before the next item at its column, an inline comment after the item last
// written on its line, and a foot after the last item of the open collection at the column of its items. A comment
// before the first item is held until that item or the close.
@(private)
block_comment :: proc(b: ^Block_Writer, role: core.Role, text: string) {
	l := &b.levels[b.top - 1] if b.top > 0 else nil
	col := int(l.col) if l != nil else 0
	if l != nil && l.n == 0 && role != .Comment_Inline {
		append(&b.held, strings.clone(text))
		return
	}
	if role == .Comment_Inline && !b.ended {
		write.put_byte(b.out, ' ')
	} else {
		if !b.ended {
			write.put_byte(b.out, '\n')
		}
		write.put_run(b.out, col, ' ')
	}
	write.put_comment(b.out, "#", text, true, col)
	write.put_byte(b.out, '\n')
	b.ended = true
}

// Writes the one-line inline comment `text` on the block collection after a key that closed last, on the key's line,
// joined to one written there, and returns whether it did. Nothing may have been written since the close.
@(private)
block_inline_back :: proc(b: ^Block_Writer, text: string) -> bool {
	out := b.out
	if b.closed[1] != out.flushed + out.cursor || b.closed[0] < out.flushed || out.stream.procedure != nil {
		return false
	}
	at := b.closed[0] - out.flushed
	tail := out.cursor - at
	write.put_text(out, " " if b.noted else " # ")
	write.put_text(out, text)
	moved := out.cursor - at - tail
	slice.rotate_right(out.buf[at:out.cursor], moved)
	b.closed, b.noted = {b.closed[0] + moved, out.flushed + out.cursor}, true
	return true
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

// Writes the string `s` as the next item, after `tag` when it is given, as a plain, quoted or literal scalar.
@(private)
block_string :: proc(b: ^Block_Writer, s: string, tag := "") -> core.Typed_Error_Kind {
	at := block_lead(b, false)
	if tag != "" {
		write.put_text(b.out, tag)
		write.put_byte(b.out, ' ')
	}
	shape, kind := shape_of(s, {block = true, tagged = tag != "", ascii = b.ascii})
	if kind != .None {
		return kind
	}
	if shape == .Literal {
		put_block(b.out, s, shape, at)
		b.ended = true
	} else {
		put_scalar(b.out, s, shape, b.ascii)
	}
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
	block_drop_held(b)
	delete(b.held)
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
	if text[at] == '"' || text[at] == '\'' {
		return quoted_end(text, at)
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
