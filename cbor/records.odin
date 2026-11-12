#+private
package cbor

import "base:runtime"
import core "../core"
import "../core/records"

// A CBOR sequence (RFC 8742) reads as records, one per item.
@(rodata)
FRAMING := records.Framing_Services {
	next  = {.Lines = nil, .Seq = nil, .Concatenated = next_item, .Entries = nil},
	judge = judge_item,
	whole = proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) {return as, .Concatenated, 0},
}

// What a reader reads of a record's value: its document.
@(rodata)
RECORD_DOCS := records.Record_Docs {
	build = build_record,
}

// Frames the item at the reader's position: the bytes from there through the item's end.
next_item :: proc(it: ^records.Reader) -> (rec: records.Record, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) {
		return
	}
	h: core.No_Hooks
	regs: core.Hook_Regs
	hi, fault := walk_rules(it.src, lo, handle_rules(it.as), &h, &regs, core.no_hook)
	if fault != nil {
		it.fault = fault
		return
	}
	it.pos = hi
	return {text = it.src[lo:hi], at = lo}, true
}

judge_item :: proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) {
	fault, bad := validate_text(rec.text, handle_rules(it.as)).?
	if bad {
		fault.at += rec.at
		return fault
	}
	return nil
}

build_record :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_item(rec.text, it.as, false, allocator)
	core.move_document_error(&err, rec.at)
	return doc, err
}
