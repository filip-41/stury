package records

// The record writer: values, texts or cells written one at a time, each framed as one record of a list. It keeps a token
// write for its life, whose format writes a typed value through the plan's walk and cells through its `value` calls,
// so a run of records sets up once.

import "core:io"
import core ".."
import typed "../typed"
import cw "../write"

// A writer of records. It is not copied after `writer_init`.
Writer :: struct {
	tokens:  cw.Tokens,
	framing: core.Framing,
	final:   bool, // `err` ends the writer: every later call returns its kind
	err:     core.Typed_Error, // the last refusal, with its path
}

// Starts a writer of records in format `as`, framed by `framing`, to `w`, or with no stream procedure into a buffer from
// `allocator` that `writer_end` returns. JSON ends a record with LF, and under `.Seq` also puts 0x1E before it. A
// delimited text's rows end themselves and take `.Lines` alone. `.Entries` is one document, which `write.marshal` writes,
// so it is `.Unsupported`, and pretty JSON under `.Lines` is `.Bad_Option`. A refusal here is final.
writer_init :: proc(wr: ^Writer, w: io.Stream, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator) -> core.Typed_Error_Kind {
	kind := cw.tokens_init(&wr.tokens, as, opts, allocator, w)
	flat := kind == .None && wr.tokens.spell.line != nil
	switch {
	case kind != .None:
	case framing == .Entries, flat && framing != .Lines:
		kind = .Unsupported
	case !flat && opts.pretty && framing == .Lines:
		kind = .Bad_Option
	}
	// A record is written around the token grammar, which then takes no JSON value call.
	wr.tokens.done = true
	wr.framing, wr.final, wr.err = framing, kind != .None, {kind = kind}
	return kind
}

// Ends the writer and returns its error, and for a buffer writer the text, which the caller owns. Every later call is
// `.Out_Of_Order`.
writer_end :: proc(wr: ^Writer) -> ([]u8, core.Typed_Error) {
	if wr.tokens.spell == nil {
		return nil, wr.err
	}
	if wr.final {
		wr.tokens.err = wr.err.kind
	}
	text, err := cw.tokens_finish(&wr.tokens)
	wr.tokens.spell = nil
	if wr.final {
		return nil, wr.err
	}
	// The tokens are freed: every later call is out of order.
	wr.final, wr.err = true, {kind = .Out_Of_Order}
	return text, err
}

// Frees what a writer holds when `writer_end` did not run, and flushes nothing. After `writer_end` it does nothing.
writer_destroy :: proc(wr: ^Writer) {
	if wr.tokens.spell != nil {
		wr.tokens.err = .Unsupported
		cw.tokens_finish(&wr.tokens)
		wr.tokens.spell = nil
	}
}

// Writes `value` as one record by `plan`, a plan of its type built by the writer's format, a row's for a delimited
// text. The first row writes the header, and every row takes the plan of the first. A refused value leaves no byte of
// its record when none was flushed since the record began, and the writer goes on. Otherwise the refusal is final.
// Each call returns the refusal's kind, and `wr.err` holds it with its path.
write :: proc(wr: ^Writer, value: any, plan: ^typed.Plan) -> core.Typed_Error_Kind {
	if wr.final {
		return wr.err.kind
	}
	if value.data == nil || mismatched(wr, value.id, plan) {
		wr.err = {kind = .Plan_Mismatch}
		return .Plan_Mismatch
	}
	return record(wr, value.data, plan)
}

@(private)
mismatched :: proc(wr: ^Writer, id: typeid, plan: ^typed.Plan) -> bool {
	return plan == nil || id != plan.type || plan.spelling == nil || plan.spelling.tokens != rawptr(wr.tokens.spell)
}

@(private)
record :: #force_inline proc(wr: ^Writer, value: rawptr, plan: ^typed.Plan) -> core.Typed_Error_Kind {
	t := &wr.tokens
	begin(wr)
	return end(wr, t.spell.record(t, plan, value, &wr.err), true)
}

// Writes `text` as one record, framed. It is the caller's text of one value or row and is written as it is, not judged.
write_text :: proc(wr: ^Writer, text: []u8) -> core.Typed_Error_Kind {
	t := &wr.tokens
	if wr.final {
		return wr.err.kind
	}
	begin(wr)
	cw.put_text(t.out, string(text))
	return end(wr, t.spell.line(t) if t.spell.line != nil else .None, false)
}

// Writes `cells` as one row of a delimited text, each as the typed write writes a string. A nil cell is empty and has
// no quotes, and a row of one nil cell is written as an empty quoted cell, since an empty line is no record. A writer
// of another format is `.Unsupported`.
write_cells :: proc(wr: ^Writer, cells: []Maybe(string)) -> core.Typed_Error_Kind {
	t := &wr.tokens
	if wr.final {
		return wr.err.kind
	}
	if t.spell.line == nil {
		wr.err = {kind = .Unsupported}
		return .Unsupported
	}
	begin(wr)
	for c in cells {
		if s, ok := c.?; ok || len(cells) == 1 {
			cw.value_string(t, s)
		} else {
			cw.value_null(t)
		}
	}
	return end(wr, cw.end_record(t), false)
}

// Writes `list` as records, each by `plan`, a plan of the element type, into new bytes from `allocator`. The first
// refused element is the error, with no text.
marshal :: proc(list: []$E, plan: ^typed.Plan, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	return marshal_to(list, plan, as, framing, opts, {}, allocator)
}

// `marshal` to `w`, as the text is made. On a refusal `w` may hold a prefix of the text.
marshal_stream :: proc(w: io.Stream, list: []$E, plan: ^typed.Plan, as: core.As, framing := core.Framing.Lines, opts := core.Write_Options{}) -> core.Typed_Error {
	_, err := marshal_to(list, plan, as, framing, opts, w, context.allocator)
	return err
}

@(private)
marshal_to :: proc(list: []$E, plan: ^typed.Plan, as: core.As, framing: core.Framing, opts: core.Write_Options, stream: io.Stream, allocator := context.allocator) -> ([]u8, core.Typed_Error) {
	wr: Writer = ---
	if writer_init(&wr, stream, as, framing, opts, allocator) == .None && mismatched(&wr, E, plan) {
		wr.err, wr.final = {kind = .Plan_Mismatch}, true
	}
	for &v in list {
		if wr.final {
			break
		}
		wr.final = record(&wr, &v, plan) != .None
	}
	return writer_end(&wr)
}

// Marks where a record begins and writes what goes before it.
@(private)
begin :: #force_inline proc(wr: ^Writer) {
	t := &wr.tokens
	t.mark = t.out.flushed + t.out.cursor
	if wr.framing == .Seq {
		cw.put_byte(t.out, 0x1E)
	}
}

// Ends a record with its frame and returns `kind`, or the output's failure. `pathed` says `wr.err` already holds the
// refusal's path.
@(private)
end :: #force_inline proc(wr: ^Writer, kind: core.Typed_Error_Kind, pathed: bool) -> core.Typed_Error_Kind {
	t := &wr.tokens
	if t.spell.line == nil {
		cw.put_byte(t.out, '\n')
	}
	if kind != .None || t.out.err != .None {
		return refused(wr, kind, pathed)
	}
	return .None
}

// A refused record goes back to its start when none of it was flushed, else the refusal is final, as an output's failure
// always is.
@(cold, private)
refused :: proc(wr: ^Writer, kind: core.Typed_Error_Kind, pathed: bool) -> core.Typed_Error_Kind {
	t := &wr.tokens
	if t.out.err != .None {
		wr.err, wr.final = {kind = t.out.err, cause = t.out.cause}, true
		return wr.err.kind
	}
	if !pathed {
		wr.err = {kind = kind}
	}
	if t.mark >= t.out.flushed {
		t.out.cursor = t.mark - t.out.flushed
		t.err, t.first = .None, true
	} else {
		wr.final = true
	}
	return kind
}
