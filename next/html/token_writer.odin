package html

import "core:io"
import "stury:lib/ops/write"

// Streaming HTML5 token writer over `write.Tape_Writer`.
Writer :: struct {
	tw: write.Tape_Writer,
}

@(require_results)
writer_start :: proc(w: ^Writer, spec := Spec.Html, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	write_check(u8(spec), opts) or_return
	return write.tape_writer_start(&w.tw, u8(spec), opts, sink, allocator, write_out)
}

@(require_results)
token :: proc(w: ^Writer, kind: Token_Kind, text := "") -> Write_Error {
	return write.token_tape_take(&w.tw.tokens, kind, text)
}

@(require_results)
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	return write.tape_writer_end(&w.tw)
}

writer_drop :: proc(w: ^Writer) {
	write.tape_writer_drop(&w.tw)
}
