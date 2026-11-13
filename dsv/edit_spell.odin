package dsv

// A value spelled as the cells of a delimited text for an edit.

import "base:runtime"
import "core:math"
import "core:strings"
import core "../core"
import write "../core/write"
import records "../core/records"

// The text of `v` at byte `at`: one cell, or with `record` the cells of an array in order, or of an object in the header's
// order for a headed table and its own order otherwise, a column it names that the header lacks refused, one the object
// lacks empty. A record is written without its line end. A refusal names the cell by its place in the record.
edit_spell :: proc(doc: ^core.Document, v: core.Value, _: core.Write_Options, _: string, record: bool, at: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	if !record {
		text, reason := spell_cell(doc, v, at, allocator)
		return text, refusal(reason, 0)
	}
	out := make([dynamic]u8, allocator)
	delimiter := doc.as.opts[0]
	cells := record_cells(doc, v)
	for cell, i in cells {
		if i > 0 {
			append(&out, delimiter)
		}
		text, reason := spell_cell(doc, cell, at, context.temp_allocator)
		if reason != .None {
			delete(out)
			return nil, refusal(reason, i)
		}
		append(&out, ..text)
	}
	return out[:], nil
}

@(private = "file")
record_cells :: proc(doc: ^core.Document, v: core.Value) -> []core.Value {
	cells := make([dynamic]core.Value, context.temp_allocator)
	if core.kind(v) == .Array {
		it := core.children(v)
		for c in core.child_next(&it) {
			append(&cells, c)
		}
		return cells[:]
	}
	if core.header_of(doc) == 0 {
		it := core.pairs(v)
		for _, c in core.pair_next(&it) {
			append(&cells, c)
		}
		return cells[:]
	}
	keys := core.children(doc, core.header_of(doc))
	buf: [256]u8
	for key in core.child_next(&keys) {
		name, ok := core.text(doc, key, buf[:])
		c: core.Value
		if ok {
			c, _ = core.member(v, name)
		}
		append(&cells, c)
	}
	return cells[:]
}

@(private = "file")
refusal :: proc(reason: core.Edit_Reason, cell: int) -> core.Error {
	if reason == .None {
		return nil
	}
	return core.error_of(core.Document_Error{kind = .Bad_Value, reason = reason, at = u64(cell)})
}

@(private = "file")
string_of :: proc(v: core.Value) -> string {
	#partial switch x in core.plain(v) {
	case string:
		return x
	case core.Node_Ref:
		context.allocator = context.temp_allocator
		return core.node_string(x.doc, x.node)
	}
	return ""
}

// The scalar a cell holds, null being no scalar.
@(private = "file")
scalar_of :: proc(v: core.Value) -> (scalar: write.Scalar, text: string) {
	#partial switch core.kind(v) {
	case .False:
		return write.Tree_Part.False, "false"
	case .True:
		return write.Tree_Part.True, "true"
	case .String:
		s := string_of(v)
		return s, s
	case .Number:
		if f, is_double := core.plain(v).(f64); is_double {
			if math.is_nan(f) {
				return nil, ""
			}
			if math.is_inf(f) {
				return core.Number{transmute(u64)math.copy_sign(math.F64_MAX, f), .Float}, ""
			}
		}
		if r, is_ref := core.plain(v).(core.Node_Ref); is_ref {
			if _, digits, _ := core.double_of(r); digits != "" {
				return write.Number_Literal{digits}, digits
			}
		}
		if t, is_text := core.plain(v).(^core.Number_Text); is_text {
			return write.Number_Literal{t.text}, t.text
		}
		n, _ := core.number(v)
		return n, ""
	}
	return nil, ""
}

// The text of one delimited cell at byte `at`: the format's own writer spells the quotes and escapes. A null cell is
// empty.
@(private = "file")
spell_cell :: proc(doc: ^core.Document, v: core.Value, at: u64, allocator: runtime.Allocator) -> ([]u8, core.Edit_Reason) {
	// A cell of the document keeps its bytes.
	if r, is_ref := core.plain(v).(core.Node_Ref); is_ref && r.doc == doc && core.kind(v) != .Array && core.kind(v) != .Object {
		joined, _ := strings.clone(string(core.span(doc, r.node)), allocator)
		return transmute([]u8)joined, .None
	}
	kind := core.kind(v)
	if kind == .Array || kind == .Object {
		return nil, .Not_Scalar
	}
	scalar, cell := scalar_of(v)
	if kind == .Null || scalar == nil {
		return nil, .None
	}
	tsv := doc.as.opts[0] == '\t'
	// An empty string is the one text a TSV cell cannot tell from null.
	if kind == .String && len(cell) == 0 && tsv {
		return nil, .Empty_Text
	}
	// A TSV cell has no quotes, so a byte order mark it starts with is refused only where it would start the text.
	bom := ""
	if tsv && strings.has_prefix(cell, "\xef\xbb\xbf") && at > core.text_start(doc.src, 0) {
		bom, cell = cell[:3], cell[3:]
	}
	wr: records.Writer
	if records.writer_init(&wr, {}, doc.as, .Lines, allocator = context.temp_allocator, spell = &TOKENS) != .None {
		return nil, .No_Spelling
	}
	if kind == .String {
		scalar = cell
	}
	cells := [1]write.Scalar{scalar}
	if records.write_cells(&wr, cells[:]) != .None {
		reason := core.Edit_Reason.No_Spelling
		if strings.has_prefix(cell, "\xef\xbb\xbf") {
			reason = .Starts_With_Mark
		} else if kind == .String && doc.readers.resolves != nil && doc.readers.resolves(doc.as) {
			reason = .Reads_Back_Typed
		}
		return nil, reason
	}
	out, err := records.writer_end(&wr)
	if err != nil {
		return nil, .No_Spelling if !strings.has_prefix(cell, "\xef\xbb\xbf") else .Starts_With_Mark
	}
	text := strings.trim_right(string(out), "\r\n")
	// A table cell is a string or null, and a quoted empty one is the string.
	if kind == .String && len(text) == 0 && bom == "" {
		text = `""`
	}
	joined, _ := strings.concatenate({bom, text}, allocator)
	return transmute([]u8)joined, .None
}
