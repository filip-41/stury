// Draft conversion (normalizes Draft 4 / 6 / 7 / 2019-09 / 2020-12 schemas to Draft 2020-12 JSON)
// and row-by-row document checking helpers.
package schema

import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

@(require_results)
convert_to_2020_12 :: proc(doc: ^tape.Document, opts := Options{}, wopts := Write_Options{}, allocator := context.allocator) -> ([]u8, Error) {
	res := Resolver{loader = opts.loader, parse = opts.parse, parse_data = opts.parse_data, draft = opts.draft, format_assert = opts.format_assert}
	defer resolver_destroy(&res)
	d, rerr := read(doc, tape.ROOT, opts.base, &res, allocator)
	if rerr.kind != .None { return nil, rerr }
	defer rules.description_destroy(&d)
	return write_schema(&d, wopts, allocator)
}

@(require_results)
check_written :: proc(c: ^Compiled, doc: ^tape.Document, rows: bool, sink: ^check.Sink = nil, allocator := context.allocator) -> check.Result {
	if !rows { return check_document(c, doc, sink, allocator) }
	if c == nil || doc == nil { return {valid = false, err = {kind = .Bad_Option, keyword = "rows"}} }
	if doc.partial != nil { return {valid = false, err = {kind = .Unsupported, keyword = "partial"}} }
	if len(doc.nodes) == 0 || doc.nodes[0].kind != .Array { return {valid = false, err = {kind = .Bad_Option, keyword = "rows"}} }
	rd := tape.Reader{doc = doc}
	it, p, err := tape.children(rd, tape.ROOT, allocator)
	if err != nil { return {valid = false, err = {kind = .No_Memory}} }
	defer tape.destroy_children(&it)
	if p != .Found { return {valid = true} }
	copts := check.Options{dups = c.opts.dups, budget = c.opts.budget}
	first_fail: check.Result
	has_fail := false
	for {
		_, row_idx, cp := tape.next_child(rd, &it)
		if cp != .Found { break }
		r := check.check_document_node(doc, row_idx, &c.plan, copts, sink, allocator)
		if !r.valid {
			if !has_fail { first_fail, has_fail = r, true } else { check.result_destroy(&r) }
			if sink == nil { break }
		} else {
			check.result_destroy(&r)
		}
	}
	return first_fail if has_fail else {valid = true}
}
