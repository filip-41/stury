package json

import "core:io"
import "core:unicode/utf8"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The token writer: a caller writes a JSON, JSONC or JSON5 text one token at a time, with the options and spelling of
// `write`. `write.Sequence` judges the order, so a malformed sequence is refused where it is written.

// A text being written token by token. It points into itself, so it is not copied once `writer_start` returns.
Writer :: struct {
	out:  write.Out,
	seq:  write.Sequence,
	opts: Write_Options,
}

// Starts `w` to write a text of `spec` under `opts` into `sink`, or into a buffer from `allocator` when `sink` has no
// procedure, which `writer_end` returns. `opts.framing` makes each root value a record and lets there be any number of
// them. `opts.node`, `opts.sort_keys` and `opts.format` have no meaning for tokens, and `opts.format` is
// `Bad_Option{"format"}`.
writer_start :: proc(w: ^Writer, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	if opts.format != nil {
		return tape.Bad_Option{"format"}
	}
	if opts.framing == .Lines && !write.compact(opts) {
		return tape.Bad_Option{"framing"}
	}
	w^ = {opts = opts}
	write.sequence_start(&w.seq, opts.framing != .None, 0, allocator)
	if e := write.out_start(&w.out, allocator, sink, 0); e != nil {
		write.sequence_drop(&w.seq)
		return e
	}
	return nil
}

// Writes `kind` with its `text`: the decoded text of a `.Key` or `.String`, which must be UTF-8, and the decimal text
// of a `.Number`, which must be a JSON number. The other kinds take none. A token the sequence cannot take here is
// `Refused{index, .Malformed}`, and a text with no JSON spelling `Refused{index, .No_Spelling}`; neither writes a
// byte, and the writer takes the next token. A refused allocation or a failed sink ends the writer.
token :: proc(w: ^Writer, kind: write.Token_Kind, text := "") -> Write_Error {
	if w.out.err != nil {
		return w.out.err
	}
	switch kind {
	case .Key, .String:
		if !utf8.valid_string(text) {
			return write.Refused{tape.Node_Index(w.seq.taken), .No_Spelling}
		}
	case .Number:
		if !write.is_json_number(transmute([]u8)text) {
			return write.Refused{tape.Node_Index(w.seq.taken), .No_Spelling}
		}
	case .Object, .Array, .True, .False, .Null, .Close:
	}
	p, err := write.sequence_take(&w.seq, kind)
	if err != nil {
		return err
	}
	out := &w.out
	pretty := !write.compact(w.opts)
	switch kind {
	case .Close:
		if pretty && !p.empty {
			put_line(out, w.opts, p.depth)
		}
		write.put_byte(out, '}' if p.object else ']')
	case .Key:
		if !p.first {
			write.put_byte(out, ',')
		}
		if pretty {
			put_line(out, w.opts, p.depth)
		}
		put_text_string(out, w.opts, text)
		write.put_byte(out, ':')
		if pretty {
			write.put_byte(out, ' ')
		}
	case .Object, .Array, .String, .Number, .True, .False, .Null:
		if p.root && w.opts.framing == .Seq {
			write.put_byte(out, RECORD_SEPARATOR)
		}
		if !p.root && !p.value {
			if !p.first {
				write.put_byte(out, ',')
			}
			if pretty {
				put_line(out, w.opts, p.depth)
			}
		}
		switch kind {
		case .Object: write.put_byte(out, '{')
		case .Array: write.put_byte(out, '[')
		case .String: put_text_string(out, w.opts, text)
		case .Number: write.put(out, transmute([]u8)text)
		case .True: write.put(out, transmute([]u8)string("true"))
		case .False: write.put(out, transmute([]u8)string("false"))
		case .Null: write.put(out, transmute([]u8)string("null"))
		case .Key, .Close:
		}
	}
	if w.opts.framing != .None && w.seq.depth == 0 && kind != .Key {
		write.put_byte(out, '\n')
	}
	return w.out.err
}

// Ends the text. The bytes of a buffer writer are returned, which the caller owns and frees with its allocator, and a
// sink writer returns none. A text that is no whole sequence, a container open or no root value, is
// `Refused{index, .Malformed}`, which leaves no text, though a sink holds what it was given. `w` is not used again.
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	whole := write.sequence_done(&w.seq) || w.opts.framing != .None && w.seq.depth == 0
	taken := w.seq.taken
	write.sequence_drop(&w.seq)
	if !whole {
		write.out_drop(&w.out)
		return nil, write.Refused{tape.Node_Index(taken), .Malformed}
	}
	return write.out_finish(&w.out)
}

// A line end and the indent of `depth` levels.
@(private)
put_line :: proc(out: ^write.Out, opts: Write_Options, depth: int) {
	write.put_byte(out, '\n')
	unit, width := u8(' '), int(opts.indent)
	if opts.tab {
		unit, width = '\t', 1
	}
	for _ in 0 ..< depth * width {
		write.put_byte(out, unit)
	}
}

@(private)
put_text_string :: proc(out: ^write.Out, opts: Write_Options, s: string) {
	if opts.ascii {
		put_ascii(out, s, true)
	} else {
		put_escaped(out, s)
	}
}
