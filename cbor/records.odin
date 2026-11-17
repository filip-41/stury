#+private
package cbor

import "base:runtime"
import core "../core"
import typed "../core/typed"
import "../core/records"

// A CBOR sequence (RFC 8742) reads as records, one per item.
@(rodata)
FRAMING := records.Framing_Services {
	next   = {.Lines = nil, .Seq = nil, .Concatenated = next_item, .Entries = records.entries_walked},
	judge  = records.no_judge,
	close  = records.entries_walked_close,
	closed = {.Lines = false, .Seq = false, .Concatenated = true, .Entries = true},
	entry_step = step_entries,
	entry_build = build_record,
	whole  = proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) {return as, .Concatenated, 0},
}

// What a reader reads of a record's value: its typed read and its document.
@(rodata)
RECORD_DOCS := records.Record_Docs {
	read  = read_item_record,
	build = build_record,
}

// The cursor of `.Entries`, with the walk's state before its last step.
Entry_Cursor :: struct {
	cursor: Cursor,
	back:   Held,
	saved:  bool,
}

// The walk of `.Entries` from the reader's position, or its resume, and the cursor's part in following a stream's
// window. Its frames hold counts, so only the places of its stop and, in a spec that orders keys, of each open map's last
// key move with the window, and those keys stay in it.
step_entries :: proc(it: ^records.Reader, w: ^records.Entry_Walk, op: records.Entry_Op) -> (hi: u64, fault: Maybe(core.Fault)) {
	e := (^Entry_Cursor)(w.cursor)
	rules := handle_rules(it.as)
	switch op {
	case .Step:
		if e == nil {
			failed: runtime.Allocator_Error
			if e, failed = new(Entry_Cursor, it.allocator); failed != nil {
				return 0, core.Fault{kind = .No_Memory}
			}
			w.cursor, w.abutting = e, true
			e.cursor.src, e.cursor.n, e.cursor.allocator = raw_data(it.src), u64(len(it.src)), it.allocator
		}
		hi, fault, _ = walk_stopped(it.src, it.pos, rules, w, nil, records.entry_hook, &e.cursor)
	case .Free:
		if e != nil {
			cursor_destroy(&e.cursor)
			free(e, it.allocator)
			w.cursor = nil
		}
	case .Save:
		if e != nil {
			e.saved = e.cursor.held != nil
			if e.saved {
				held_copy(&e.back, e.cursor.held)
			}
		}
	case .Restore:
		if !e.saved {
			cursor_destroy(&e.cursor)
		} else if e.cursor.held != nil || hold(&e.cursor, 0, {}, nil, nil, {}) == 0 {
			held_copy(e.cursor.held, &e.back)
		} else {
			return 0, core.Fault{kind = .No_Memory}
		}
	case .Rebase:
		e.cursor.src, e.cursor.n = raw_data(it.src), u64(len(it.src))
		if s := e.cursor.held; s != nil {
			delta := int(w.delta)
			s.place.i -= delta
			s.place.start = max(s.place.start - delta, 0)
			s.place.fold.lo -= min(s.place.fold.lo, w.delta)
			for &prev, k in s.prevs[:s.place.d] {
				if rules.spec != .Cbor && prev[0] != 0 && held_map(s, k + 1) {
					prev -= {w.delta, w.delta}
				}
			}
		}
	case .Clone:
		return 0, core.Fault{kind = .Bad_Option}
	case .Keep:
		hi = max(u64)
		if s := e.cursor.held; s != nil && rules.spec != .Cbor {
			hi = u64(s.place.start)
			for prev, k in s.prevs[:s.place.d] {
				if prev[0] != 0 && held_map(s, k + 1) {
					hi = min(hi, prev[0])
				}
			}
		}
	}
	return
}

// Copies the state `from` holds to `to`, its open frames alone.
@(private)
held_copy :: proc "contextless" (to, from: ^Held) {
	d := from.place.d
	to.place, to.regs = from.place, from.regs
	copy(to.stack[:d], from.stack[:d])
	copy(to.prevs[:d], from.prevs[:d])
}

// Whether the frame at depth `k` of a held walk is a map.
@(private)
held_map :: proc "contextless" (s: ^Held, k: int) -> bool {
	frame := s.stack[k] if k < s.place.d else s.place.top
	return frame & FLAG_OBJECT != 0
}

// Frames the item at the reader's position: the bytes from there through the item's end, judged by the walk that
// frames them.
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

build_record :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_item(rec.text, it.as, false, allocator)
	core.move_document_error(&err, rec.at)
	return doc, err
}

// Reads the next item of a sequence into `target` by the walk that frames it. A refusal that stops the walk, and a fault,
// leave the record's end or its fault to `next_item`. `.Refuse` reads the framed item's text, which notes its keys
// first, and `.Entries` is read through its walk's tree by `records`.
read_item_record :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal) -> bool {
	if it.framing != .Concatenated || read.dups == .Refuse {
		rec := records.frame_text(it) or_return
		kept := typed.sink_mark(read.sink)
		err^ = read_text(rec.text, Spec(it.as.spec), options_of(it.as), target, T, plan, read, allocator, false)
		records.move_refused(err, read, kept, rec.at)
		return true
	}
	if it.pos >= u64(len(it.src)) {
		return false
	}
	kept := typed.sink_mark(read.sink)
	hi, cut := item_walked(it.src, it.pos, it, Spec(it.as.spec), options_of(it.as), target, T, plan, read, it.frames, allocator, err, false, false, true)
	if !cut && hi == 0 {
		return false
	}
	if cut {
		if _, ok := next_item(it); !ok {
			typed.sink_restore(read.sink, kept)
			return false
		}
		return true
	}
	it.pos = hi
	return true
}
