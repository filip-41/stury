package records

import "../kernel"
import core ".."

// A record `skip` went past: its bytes less the whitespace around them, the input offsets of its first byte and of the
// byte past it, and the fault it holds. On a stream `text` is the part of it the window still holds, which is its last
// part when it spanned windows.
Bad_Record :: struct {
	text:  []u8,
	at:    u64,
	end:   u64,
	fault: core.Fault,
}

// Goes on past the record that holds the fault the records ended on, after `next`, `read` or `scan` returned false, so
// that the next call reads the record after it, and returns that record. The record runs from the first byte past the
// record before it that is no whitespace up to the next place the framing marks a record's start whatever the bytes
// before it: a YAML stream's next document, a dsv row's next line, and under `.Concatenated` in JSON the line after the
// fault, or the fault's own line when the fault is that line's first byte that is no whitespace. A bad record with no
// such place after it runs to the input's end. Returns false, with the fault kept, for a fault at no byte, a record
// longer than a stream's bound, a fault in a dsv header, and under a framing with no such place: `.Entries`, CBOR, and
// the formats read as one document. Under `.Lines` and `.Seq` in JSON a record's fault comes from what reads its text,
// and the next call goes on past it with no `skip`.
skip :: proc(it: ^Reader) -> (bad: Bad_Record, ok: bool) {
	f, faulted := it.fault.?
	if !faulted || f.kind in core.AT_NO_BYTE || f.rules == &RULES || it.services == nil || it.services.resume == nil {
		return
	}
	from := f.at - it.base
	lo := min(it.pos, from)
	next := it.services.resume(it, from) or_return
	it.fault = nil
	for lo < min(next, u64(len(it.src))) && kernel.is_ws(it.src[lo]) {
		lo += 1
	}
	bad.at, bad.fault = it.base + lo, f
	// The record spans windows until one holds a mark past it, or the input ends.
	for next == max(u64) && it.input.procedure != nil && !it.last {
		it.pos = u64(len(it.src))
		end := it.base + it.pos
		if !window_move(it, hold_cut = false) {
			bad.end = end
			return bad, true
		}
		lo = it.pos
		next, _ = it.services.resume(it, it.pos)
	}
	next = min(next, u64(len(it.src)))
	hi := next
	for hi > lo && kernel.is_ws(it.src[hi - 1]) {
		hi -= 1
	}
	bad.text, bad.end = it.src[lo:hi], it.base + hi
	it.pos = next
	return bad, true
}
