// Compiled schema handle (`Compiled`) combining `read` + `check.compile` cleanly on v2's `check.Plan`.
package schema

import "base:runtime"
import "core:slice"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

Options :: struct {
	format_assert: bool,
	base:          string,
	loader:        Ref_Loader,
	parse:         Parse_Proc,
	parse_data:    rawptr,
	draft:         Maybe(Draft),
	dups:          tape.Duplicates,
	budget:        tape.Budget,
}

Compiled :: struct {
	description:      ^rules.Description,
	plan:             check.Plan,
	opts:             Options,
	doc:              tape.Document,
	owns_doc:         bool,
	owns_description: bool,
	res:              Resolver,
	allocator:        runtime.Allocator,
}

@(require_results)
compile_document :: proc(doc: ^tape.Document, node := tape.ROOT, opts := Options{}, allocator := context.allocator) -> (^Compiled, Error) {
	c := new(Compiled, allocator)
	if c == nil { return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	if err := compile_into(c, doc, node, opts, allocator); err.kind != .None {
		destroy(c)
		return nil, err
	}
	return c, {}
}

@(require_results)
compile_json :: proc(src: []u8, opts := Options{}, allocator := context.allocator) -> (^Compiled, Error) {
	c := new(Compiled, allocator)
	if c == nil { return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	c.allocator = allocator
	tmp_res := Resolver{parse = opts.parse, parse_data = opts.parse_data}
	doc, ok := parse_schema_bytes(&tmp_res, src, allocator)
	if !ok {
		free(c, allocator)
		return nil, make_error(.Parse, "schema", "failed to parse schema JSON", allocator = allocator)
	}
	c.doc, c.owns_doc = doc, true
	if err := compile_into(c, &c.doc, tape.ROOT, opts, allocator); err.kind != .None {
		destroy(c)
		return nil, err
	}
	return c, {}
}

@(private = "file")
compile_into :: proc(c: ^Compiled, doc: ^tape.Document, node: tape.Node_Index, opts: Options, allocator: runtime.Allocator) -> Error {
	c.opts, c.allocator = opts, allocator
	c.res = {loader = opts.loader, parse = opts.parse, parse_data = opts.parse_data, draft = opts.draft, format_assert = opts.format_assert}
	desc := new(rules.Description, allocator)
	if desc == nil { return make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	c.description, c.owns_description = desc, true
	d, rerr := read(doc, node, opts.base, &c.res, allocator)
	if rerr.kind != .None { return rerr }
	c.description^ = d
	plan, cerr := check.compile(c.description, allocator)
	if cerr.kind != .None { return Error{kind = .Compile, keyword = cerr.keyword, compile_err = cerr} }
	c.plan = plan
	return {}
}

@(require_results)
compile_description :: proc(d: ^rules.Description, opts := Options{}, allocator := context.allocator) -> (^Compiled, Error) {
	if d == nil { return nil, make_error(.Bad_Option, "description", "nil description", allocator = allocator) }
	c := new(Compiled, allocator)
	if c == nil { return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator) }
	c^ = {description = d, opts = opts, allocator = allocator}
	asserted: rules.Description
	work := d
	if opts.format_assert {
		asserted = asserting(d, true, allocator)
		work = &asserted
	}
	defer asserting_destroy(&asserted, opts.format_assert, allocator)
	plan, cerr := check.compile(work, allocator)
	if cerr.kind != .None {
		destroy(c)
		return nil, Error{kind = .Compile, keyword = cerr.keyword, compile_err = cerr}
	}
	c.plan = plan
	return c, {}
}

destroy :: proc(c: ^Compiled) {
	if c == nil { return }
	a := c.allocator
	check.plan_destroy(&c.plan)
	if c.owns_description && c.description != nil {
		rules.description_destroy(c.description)
		free(c.description, a)
	}
	resolver_destroy(&c.res)
	if c.owns_doc { tape.destroy_document(&c.doc) }
	free(c, a)
}

@(require_results)
check_document :: proc(c: ^Compiled, doc: ^tape.Document, sink: ^check.Sink = nil, allocator := context.allocator) -> check.Result {
	if c == nil { return {valid = false, err = {kind = .Bad_Option, keyword = "compiled"}} }
	return check.check_document(doc, &c.plan, {dups = c.opts.dups, budget = c.opts.budget}, sink, allocator)
}

valid_document :: proc(c: ^Compiled, doc: ^tape.Document, allocator := context.allocator) -> bool {
	res := check_document(c, doc, nil, allocator)
	ok := res.valid
	check.result_destroy(&res)
	return ok
}

@(private)
asserting :: proc(d: ^rules.Description, on: bool, allocator: runtime.Allocator) -> rules.Description {
	out := d^
	if !on { return out }
	out.nodes = slice.clone_to_dynamic(d.nodes[:], allocator)
	for &n in out.nodes { n.rules.assert_format ||= !n.rules.format_foreign }
	out.objects = slice.clone_to_dynamic(d.objects[:], allocator)
	for &o in out.objects {
		if len(o.members) > 0 {
			o.members = slice.clone(o.members, allocator)
			for &m in o.members { m.rules.assert_format ||= !m.rules.format_foreign }
		}
	}
	return out
}

@(private)
asserting_destroy :: proc(d: ^rules.Description, on: bool, allocator: runtime.Allocator) {
	if !on { return }
	delete(d.nodes)
	for o in d.objects { delete(o.members, allocator) }
	delete(d.objects)
}
