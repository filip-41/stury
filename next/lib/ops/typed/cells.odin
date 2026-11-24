package typed

import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A delimited text's records read by the places of their cells. The first record into a struct maps each column it
// takes to the member its key names, and each later record the walk replays is read by that map at its close, its
// `required` members known present, as the first record's were.

// `cells_hook` before the columns are mapped: the first record into a struct maps them, and a record into anything
// else, a repeated column or a refusal leaves every record read by its keys.
@(private)
learn_columns :: #force_inline proc "contextless" (h: ^Cells_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	#partial switch h.learn {
	case .Before:
		if t.kind == .Array && h.sp == 1 {
			#partial switch (^Record)(uintptr(s.b) - size_of(Record)).kind {
			case .Struct, .Required, .Map:
				return one_row(h, s, t)
			}
		}
		if t.kind == .Object && t.role == .Value && h.sp == RECORD_SP - 1 {
			kind := (^Record)(uintptr(s.b) - size_of(Record)).kind
			h.learn = .Learning if kind == .Struct || kind == .Required else .Off
		}
	case .Learning:
		r, a := reader_hook(&h.reader, s, t, number, true)
		if h.dead {
			h.learn = .Off
		} else if t.role == .Key && a == .Next {
			column := (^Record)(uintptr(r.b) - size_of(Record))
			// A record with a column repeated under `.Last` is read by its keys, so the repeat frees what it replaces.
			repeated := h.taken == len(h.columns)
			for taken in h.columns[:h.taken] {
				repeated ||= taken.rec == column
			}
			if repeated {
				h.learn = .Off
			} else {
				read := Cell_Read.Hook
				#partial switch column.kind {
				case .String: read = .String
				case .I64: read = .I64
				case .F64: read = .F64
				case .I8 ..= .I32, .U8 ..= .F32: read = .Number
				case .Bool: read = .Bool
				}
				h.columns[h.taken] = {column, column.offset, column.kind, read}
				h.taken += 1
			}
		} else if t.kind == .End && h.sp == RECORD_SP - 1 {
			h.learn = .Ready
		}
		return r, a
	}
	return reader_hook(&h.reader, s, t, number, true)
}

// Opens the text `t` for a target that is one row, a struct or a map: its first record is read into it, as into a list
// of one row, and a second is `.Too_Many`. The records are read by `Cells_Reader.row`, the target's record moving past
// the row.
@(private)
one_row :: #force_no_inline proc "contextless" (h: ^Cells_Reader, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.row = {(^Record)(uintptr(s.b) - size_of(Record))^, {word = NO_KEY, kind = .End}}
	h.row[0].stride = 1
	f, ok := push(&h.reader, s, nil)
	if !ok {
		return refuse_memory(&h.reader, s, t)
	}
	f.b, f.owner, f.seen = u64(uintptr(&POSITION_BLOCK[1])), &POSITION_BLOCK[0], h.frames[0].seen & SEEN_TARGET
	return {s.c + 1, u64(uintptr(&h.row[1])), s.c}, .Next
}

// A token of a replayed record: a cell, read by the column at `b`, and the record's `End`, which closes it. A cell with
// nothing to decode of a string, number or boolean member is read here, and any other through the hook.
@(private)
replay_cell :: #force_inline proc "contextless" (h: ^Cells_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) #no_bounds_check {
	if t.kind == .End {
		h.replay.replays = false
		h.sp -= 1
		f := &h.frames[h.sp]
		return {f.a, f.b, f.c + u64((^Record)(uintptr(f.b) - size_of(Record)).stride)}, .Next
	}
	column := (^Column)(uintptr(s.b))
	next := hook.Regs{s.a, s.b + size_of(Column), s.c}
	if t.kind == .String && t.spelling & tape.SPELLING_DECODE == 0 {
		dest := uintptr(s.c) + uintptr(column.offset)
		src := h.base[:h.len]
		switch column.read {
		case .Hook:
		case .String:
			if h.borrow {
				(^string)(dest)^ = string(src[t.lo:][:t.n])
			} else if !copy_span(h, dest, t.lo, t.n) {
				return refuse_memory(h, {NO_LIMIT, u64(uintptr(column.rec)) + size_of(Record), s.c}, t)
			}
			return next, .Next
		case .I64:
			if v, ok := spell.integer_short(src, t.lo, t.lo + u64(t.n)); ok {
				(^i64)(dest)^ = v
				return next, .Next
			}
		case .F64:
			if v, ok := spell.float_short(src, t.lo, t.lo + u64(t.n)); ok {
				(^f64)(dest)^ = v
				return next, .Next
			}
		case .Number:
			if v, ok := spell.number_short(src, t.lo, t.lo + u64(t.n)); ok && store_number(column.kind, v, dest) {
				return next, .Next
			}
		case .Bool:
			if t.lo + 8 <= u64(len(src)) {
				// `true` and `false` read in one load, which the eight bytes of text from the cell hold.
				w := load8(raw_data(src)[t.lo:])
				if t.n == 4 && u32(w) == 0x6575_7274 || t.n == 5 && w & 0xFF_FFFF_FFFF == 0x65_736C_6166 {
					(^bool)(dest)^ = t.n == 4
					return next, .Next
				}
			}
		}
	}
	return replay_cold(h, s, t, number)
}

// A replayed record's cell its column does not read in place, read through the hook by the column's record. A refusal
// ends the replay, so the record's other tokens reach the refused read's state.
@(private)
replay_cold :: #force_no_inline proc "contextless" (h: ^Cells_Reader, s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	column := (^Column)(uintptr(s.b))
	r, a := reader_hook(&h.reader, {NO_LIMIT, u64(uintptr(column.rec)) + size_of(Record), s.c}, t, number, true)
	if h.dead {
		h.replay.replays = false
		return r, a
	}
	return {s.a, s.b + size_of(Column), s.c}, a
}

// A string cell as the value its text spells for a field other than a string: `true` and `false` as booleans, and a
// number as a number token. False for a cell that spells neither, which the field then refuses.
@(private)
cell_value :: proc "contextless" (h: ^Reader, t: tape.Token) -> (tape.Token, bool) {
	if t.spelling & tape.SPELLING_DECODE != 0 {
		return t, false
	}
	cell := t
	switch string(h.base[t.lo:][:t.n]) {
	case "true":
		cell.kind = .True
	case "false":
		cell.kind = .False
	case:
		if _, ok := spell.number_strict(h.base[:h.len], t.lo, t.lo + u64(t.n)); !ok {
			return t, false
		}
		cell.kind = .Number
		cell.spelling = 0
	}
	return cell, true
}
