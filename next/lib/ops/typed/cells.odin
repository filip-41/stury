package typed

import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A delimited text's records read by the places of their cells. The first record into a struct maps each column it
// takes to the member its key names, and each later record the walk replays is read by that map at its close, its
// `required` members known present, as the first record's were.

// `cells_hook` before the columns are mapped: the first record into a struct maps them, and a record into anything
// else, or a refusal, leaves every record read by its keys.
@(private)
learn_columns :: #force_inline proc "contextless" (h: ^Cells_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	#partial switch h.learn {
	case .Before:
		if t.kind == .Object && t.role == .Value && h.sp == RECORD_SP - 1 {
			kind := (^Record)(uintptr(s.b) - size_of(Record)).kind
			h.learn = .Learning if kind == .Struct || kind == .Required else .Off
		}
	case .Learning:
		r, a := reader_hook(&h.reader, s, t, number, true)
		if h.dead {
			h.learn = .Off
		} else if t.role == .Key {
			if a == .Next && h.taken == len(h.columns) {
				h.learn = .Off
			} else if a == .Next {
				h.columns[h.taken] = (^Record)(uintptr(r.b) - size_of(Record))
				h.taken += 1
			}
		} else if t.kind == .End && h.sp == RECORD_SP - 1 {
			h.learn = .Ready
		}
		return r, a
	}
	return reader_hook(&h.reader, s, t, number, true)
}

// Reads the cells of a replayed record at its `End`, each by the member its column maps to, and closes the record.
@(private)
replay_record :: #force_no_inline proc "contextless" (h: ^Cells_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	h.replay.replays = false
	for cell, k in h.replay.cells[:min(h.replay.given, h.taken)] {
		r, a := reader_hook(&h.reader, {NO_LIMIT, u64(uintptr(h.columns[k])) + size_of(Record), s.c}, cell, number, true)
		if h.dead {
			return r, a
		}
	}
	h.sp -= 1
	f := &h.frames[h.sp]
	return {f.a, f.b, f.c + u64((^Record)(uintptr(f.b) - size_of(Record)).stride)}, .Next
}
