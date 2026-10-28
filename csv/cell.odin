package csv

// The integer cell reader of `unmarshal`. A float cell is read by `core_pkg.number_of_loose_text`.

import core_pkg "../core"

@(private)
read_int :: proc(text: string) -> (mag: u128, over, neg: bool, fault: core_pkg.Shape_Fault) {
	src := transmute([]byte)text
	signed := len(src) > 0 && (src[0] == '-' || src[0] == '+')
	ok: bool
	if mag, over, ok = core_pkg.fold_int(src, u64(signed), u64(len(src))); !ok {
		return 0, false, false, .Wrong_Kind
	}
	return mag, over, signed && src[0] == '-', .None
}

// `text`, an integer of at most 64 bits, into the `width`-byte `signed` or unsigned integer at `dest`.
@(private)
store_int :: #force_inline proc(text: string, dest: rawptr, width: u8, signed: bool) -> core_pkg.Shape_Fault {
	mag, over, neg := read_int(text) or_return
	if over || mag > u128(max(u64)) {
		return .Out_Of_Range
	}
	return core_pkg.shape_int_store(u64(mag), neg, dest, width, signed)
}
