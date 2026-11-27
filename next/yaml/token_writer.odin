package yaml

import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The token writer: callers stream a document's tokens (`token`) and `writer_end` lays out the YAML text (block or
// flow according to `Write_Options`) via `write_out`.

Writer :: struct {
	tw: write.Tape_Writer,
}

@(require_results)
writer_start :: proc(w: ^Writer, spec := Spec.Yaml_1_2, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	write_check(u8(spec), opts) or_return
	return write.tape_writer_start(&w.tw, u8(spec), opts, sink, allocator, write_out)
}

@(require_results)
token :: proc(w: ^Writer, kind: Token_Kind, text := "") -> Write_Error {
	return write.token_tape_take(&w.tw.tokens, kind, text)
}

// Writes `node` of `doc` as tokens into `w`.
@(require_results)
put :: proc(w: ^Writer, doc: ^tape.Document, node := tape.ROOT) -> Write_Error {
	return write.tokens_of(doc, node, w, token, w.tw.allocator)
}

@(require_results)
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	return write.tape_writer_end(&w.tw)
}

writer_drop :: proc(w: ^Writer) {
	write.tape_writer_drop(&w.tw)
}
