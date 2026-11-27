package json

import "core:io"
import "stury:lib/base/kernel"
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
@(require_results)
writer_start :: proc(w: ^Writer, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	if err := check_write_opts(opts); err != nil {
		return err
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
@(require_results)
token :: proc(w: ^Writer, kind: write.Token_Kind, text := "") -> Write_Error {
	if w.out.err != nil {
		return w.out.err
	}
	switch kind {
	case .Key, .String:
		if !kernel.utf8_valid(transmute([]u8)text) {
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
	fill := u64(0x0909_0909_0909_0909) if w.opts.tab else u64(0x2020_2020_2020_2020)
	width := 1 if w.opts.tab else int(w.opts.indent)
	switch kind {
	case .Close:
		if pretty && !p.empty {
			write.line_indent(out, width, fill, p.depth)
		}
		write.put_byte(out, '}' if p.object else ']')
	case .Key:
		if !p.first {
			write.put_byte(out, ',')
		}
		if pretty {
			write.line_indent(out, width, fill, p.depth)
		}
		put_string(out, w.opts.ascii, text)
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
				write.line_indent(out, width, fill, p.depth)
			}
		}
		switch kind {
		case .Object: write.put_byte(out, '{')
		case .Array: write.put_byte(out, '[')
		case .String: put_string(out, w.opts.ascii, text)
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

// Writes value `node` of `doc`, a document of any format, as tokens into `w`, as `dsv.put` writes a record.
@(require_results)
put :: proc(w: ^Writer, doc: ^tape.Document, node := tape.ROOT) -> Write_Error {
	return write.tokens_of(doc, node, w, token, w.seq.allocator)
}

// Ends the text. The bytes of a buffer writer are returned, which the caller owns and frees with its allocator, and a
// sink writer returns none. A text that is no whole sequence, a container open or no root value, is
// `Refused{index, .Malformed}`, which leaves no text, though a sink holds what it was given. `w` is not used again.
@(require_results)
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	whole := write.sequence_done(&w.seq)
	taken := w.seq.taken
	write.sequence_drop(&w.seq)
	if !whole {
		write.out_drop(&w.out)
		return nil, write.Refused{tape.Node_Index(taken), .Malformed}
	}
	return write.out_finish(&w.out)
}

// Aborts `w` and frees its buffers without flushing or returning text. `w` is not used again.
writer_drop :: proc(w: ^Writer) {
	write.sequence_drop(&w.seq)
	write.out_drop(&w.out)
	w^ = {}
}
