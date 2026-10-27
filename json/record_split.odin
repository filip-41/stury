package json

import core_pkg "../core"

// A record is one JSON text, but a `.JSON_Seq` record can hold a complete text and then bytes that belong to
// no record: `[1]` followed by `]` before the next separator. The library's framing yields the record's
// bytes whole (`records`), and its validation names the fault. A surface that answers values needs to know
// where the value ends, which is this one rule, shared by the CLI and the library.

// The first complete JSON text at the start of `rec`, when `rec` holds one and more bytes follow it. `value`
// is that text and `fault` is what follows it, at its offset in `rec`. `split` is false for a record that is
// one text, valid or not, and the caller validates it whole. `opts.duplicates` is not read.
@(require_results)
split_record :: proc(
	rec: []byte,
	opts := Read_Opts{},
) -> (value: []byte, fault: Maybe(Error), split: bool) {
	e, bad := validate(rec, opts).?
	if !bad || e.offset == 0 || e.offset > u64(len(rec)) {
		return
	}
	// The fault's offset is where the text stops: when the bytes before it are a text of their own, the
	// record carries a value and a fault, not one faulty text. A bare number or literal ends only where a
	// delimiter says so: `nullx` or `true,` is one faulty token, not a value and a fault. Only a text that
	// closes itself, an array, object or string, stands apart.
	end := core_pkg.skip_space_back(rec, 0, int(e.offset))
	if end == 0 || (rec[end - 1] != ']' && rec[end - 1] != '}' && rec[end - 1] != '"') {
		return
	}
	if _, prefix_bad := validate(rec[:int(e.offset)], opts).?; prefix_bad {
		return
	}
	return rec[:int(e.offset)], e, true
}
