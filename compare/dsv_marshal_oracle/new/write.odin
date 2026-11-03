package dsv_marshal_oracle

import core "next:core"
import dsv "next:dsv"

read_table :: proc(src: []u8, v: ^[]Table_Row) {assert(dsv.unmarshal(src, .Csv, v).kind == .None)}
read_text :: proc(src: []u8, v: ^[]Text_Row) {assert(dsv.unmarshal(src, .Csv, v).kind == .None)}

arm :: proc(name: string, rows: $T, spec: Spec, layout: Layout) {
	chosen := dsv.Spec.Csv
	switch spec {
	case .Csv:
	case .Tsv:
		chosen = .Tsv
	case .Plain:
		chosen = .Plain
	}
	opts := dsv.Options{delimiter = layout.delimiter, comment = layout.comment, no_header = layout.no_header, crlf = layout.crlf}
	text, err := dsv.marshal(rows, chosen, opts, core.Write_Options{sort_keys = layout.sort_keys})
	if err.kind != .None {
		write_text(name, transmute([]u8)string("REFUSED\n"))
		return
	}
	write_text(name, text)
}

main :: proc() {
	marshal_values()
}
