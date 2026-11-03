package dsv_marshal_oracle

import csv "stury:csv"

read_table :: proc(src: []u8, v: ^[]Table_Row) {assert(csv.unmarshal(src, v, {borrow_strings = true}, nil, context.allocator) == nil)}
read_text :: proc(src: []u8, v: ^[]Text_Row) {assert(csv.unmarshal(src, v, {borrow_strings = true}, nil, context.allocator) == nil)}

arm :: proc(name: string, rows: $T, spec: Spec, layout: Layout) {
	quoting := csv.Quoting.Quotes
	switch spec {
	case .Csv:
	case .Tsv:
		quoting = .Backslash
	case .Plain:
		quoting = .None
	}
	delimiter := layout.delimiter
	if spec == .Tsv && delimiter == 0 {
		delimiter = '\t'
	}
	opts := csv.Marshal_Opts {
		dialect   = {delimiter = delimiter, comment = layout.comment, quoting = quoting},
		no_header = layout.no_header,
		crlf      = layout.crlf,
		sort_keys = layout.sort_keys,
	}
	buf := make([dynamic]u8)
	defer delete(buf)
	if err := csv.marshal_append(&buf, rows, opts); err != nil {
		write_text(name, transmute([]u8)string("REFUSED\n"))
		return
	}
	write_text(name, buf[:])
}

main :: proc() {
	marshal_values()
}
