package yaml

import "base:runtime"
import "core:bytes"
import core "../core"
import "../core/records"

// Frames the document at the reader's position: the bytes from there through the document's end, judged by the walk
// that frames it. A stream's last comments and blank lines hold no document, so they end the records.
@(private)
next_document :: proc(it: ^records.Reader) -> (rec: records.Record, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) || it.to != 0 && lo >= it.to {
		return
	}
	p: Parser
	parser_init(&p, it.src, options_of(it.as), nil, nil)
	defer parser_destroy(&p)
	p.pos = core.text_start(it.src, lo)
	p.ls = p.pos
	found, read := read_document(&p)
	if read {
		p.fail = core.fault_at(p.pos, .None)
	}
	hi, fault, _ := core.result_of(p.fail, &RULES)
	if fault != nil {
		it.fault = fault
		return
	}
	it.pos = max(hi, lo)
	if !found || hi <= lo {
		it.pos = u64(len(it.src))
		return
	}
	return {text = it.src[lo:hi], at = lo}, true
}

// Moves a piece's reader to the first document start at or past `it.pos` and before `to`.
@(private)
guess_document :: proc(it: ^records.Reader, to: u64) -> bool {
	if it.pos == 0 || to <= it.pos {
		return false
	}
	at := cut_document(it, it.pos - 1, to - 1) or_return
	it.pos = at
	return true
}

// A document starts past the LF before a `---` line, and past the LF that ends a `...` line, unless the last line
// before that line that is no comment or blank line is a directive or a `...` line. Every other start follows a
// `---` or `...` line too, and no line of a document is one.
@(private)
cut_document :: proc(it: ^records.Reader, lo, to: u64) -> (u64, bool) {
	src := it.src
	hi := min(to, u64(len(src)))
	if lo >= hi {
		return 0, false
	}
	p := Parser{src = src}
	ls := u64(bytes.last_index_byte(src[:lo], '\n') + 1)
	for i := lo; i < hi; {
		k := bytes.index_byte(src[i:hi], '\n')
		if k < 0 {
			break
		}
		lf := i + u64(k)
		if marker_at(&p, ls) == '.' && !lone_cr(src[ls:lf]) && ls > 0 && opens_past(&p, ls - 1) {
			return lf + 1, true
		}
		if marker_at(&p, lf + 1) == '-' && opens_past(&p, lf) {
			return lf + 1, true
		}
		ls, i = lf + 1, lf + 1
	}
	return 0, false
}

// Whether a document may start past the line that ends at the LF `lf`: the last line at or before it that is no
// comment or blank line is no directive, no `...` line and no line a byte order mark starts, and the text starts
// before none. A CR may end a line alone, so a line that holds one before its end is taken for any of them.
@(private)
opens_past :: proc(p: ^Parser, lf: u64) -> bool {
	end := lf
	for {
		ls := u64(bytes.last_index_byte(p.src[:end], '\n') + 1)
		line := p.src[ls:end]
		if lone_cr(line) {
			return false
		}
		j := 0
		for j < len(line) && (line[j] == ' ' || line[j] == '\t') {
			j += 1
		}
		if j < len(line) && line[j] != '#' && line[j] != '\r' {
			return line[0] != '%' && line[0] != 0xef && marker_at(p, ls) != '.'
		}
		if ls == 0 {
			return false
		}
		end = ls - 1
	}
}

// Whether `line` holds a CR other than one right before its LF.
@(private)
lone_cr :: #force_inline proc(line: []u8) -> bool {
	k := bytes.index_byte(line, '\r')
	return k >= 0 && k < len(line) - 1
}

// A piece reads the documents from the cut `lo`, and none that starts at or past the cut `hi`. Its text runs on past
// `hi`, so a document that is not well-formed meets the fault the serial read meets, though the cut lies inside it.
@(private)
piece_documents :: proc(it: ^records.Reader, lo, hi: u64) -> bool {
	if lo > 0 {
		it.pos = lo
	}
	if hi < u64(len(it.src)) {
		it.to = hi
	}
	return true
}

// A whole text is the documents of its stream.
@(private)
whole_stream :: proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) {
	return as, .Concatenated, 0
}

@(private)
build_document :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_as(rec.text, it.as, false, allocator)
	core.move_document_error(&err, rec.at)
	return doc, err
}
