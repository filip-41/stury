// Compiled schema handle (`Compiled`) combining `read` + `check.compile` cleanly on v2's `check.Plan`.
package schema

import "base:runtime"
import "core:slice"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

// Options for reading and compiling a schema.
Options :: struct {
	// Whether `format` asserts regardless of the schema's vocabulary.
	format_assert: bool,
	// Retrieval URI of the schema, "" for none.
	base:          string,
	// Optional VFS `$ref` loader (zero OS dependencies; WASM-safe).
	loader:        Ref_Loader,
	// Optional parser for raw schema bytes returned by `loader.load_bytes` or embedded meta-schemas.
	parse:         Parse_Proc,
	parse_data:    rawptr,
	// Default draft for a schema without `$schema` (Draft 2020-12 when nil).
	draft:         Maybe(Draft),
	// Duplicate-key policy for checks run against this compiled schema.
	dups:          tape.Duplicates,
	// Resource budget for checks run against this compiled schema.
	budget:        tape.Budget,
}

// A compiled schema ready for concurrent validation across threads (`check.Plan` is immutable and thread-safe).
// Owns its `check.Plan`, its `rules.Description` (when `owns_description`), and any VFS-loaded documents (`res`).
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

// Reads and compiles a JSON Schema from an already-parsed `tape.Document` (JSON, TOML, XML, CBOR, etc.).
// The resulting `Compiled` owns its `rules.Description` and self-contained `check.Plan`.
// If `doc` will be destroyed before `Compiled`, `Compiled.plan` remains 100% valid (it clones all values),
// though `Compiled.description` may hold `Node_Ref`s into `doc`.
@(require_results)
compile_document :: proc(doc: ^tape.Document, node := tape.ROOT, opts := Options{}, allocator := context.allocator) -> (c: ^Compiled, err: Error) {
	c = new(Compiled, allocator)
	if c == nil {
		return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	err = compile_into(c, doc, node, opts, allocator)
	if err.kind != .None {
		destroy(c)
		return nil, err
	}
	return c, {}
}

// Parses RFC 8259 JSON bytes (or uses `opts.parse` if set), reads the schema, and compiles it into `Compiled`.
@(require_results)
compile_json :: proc(src: []u8, opts := Options{}, allocator := context.allocator) -> (c: ^Compiled, err: Error) {
	c = new(Compiled, allocator)
	if c == nil {
		return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	c.allocator = allocator
	tmp_res := Resolver{parse = opts.parse, parse_data = opts.parse_data}
	doc, ok := parse_schema_bytes(&tmp_res, src, allocator)
	if !ok {
		free(c, allocator)
		return nil, make_error(.Parse, "schema", "failed to parse schema JSON", allocator = allocator)
	}
	c.doc = doc
	c.owns_doc = true
	// Read directly from `&c.doc` (stable heap address) so `Node_Ref` literals stay valid for `c`'s lifetime.
	err = compile_into(c, &c.doc, tape.ROOT, opts, allocator)
	if err.kind != .None {
		destroy(c)
		return nil, err
	}
	return c, {}
}

@(private = "file")
compile_into :: proc(c: ^Compiled, doc: ^tape.Document, node: tape.Node_Index, opts: Options, allocator: runtime.Allocator) -> Error {
	c.opts = opts
	c.res = {
		loader        = opts.loader,
		parse         = opts.parse,
		parse_data    = opts.parse_data,
		draft         = opts.draft,
		format_assert = opts.format_assert,
	}
	c.allocator = allocator
	desc := new(rules.Description, allocator)
	if desc == nil {
		return make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	c.description = desc
	c.owns_description = true
	d, rerr := read(doc, node, opts.base, &c.res, allocator)
	if rerr.kind != .None {
		return rerr
	}
	c.description^ = d
	plan, cerr := check.compile(c.description, allocator)
	if cerr.kind != .None {
		return Error{kind = .Compile, keyword = cerr.keyword, compile_err = cerr}
	}
	c.plan = plan
	return {}
}

// Compiles a `rules.Description` directly into a `Compiled` handle (borrows `d`).
@(require_results)
compile_description :: proc(d: ^rules.Description, opts := Options{}, allocator := context.allocator) -> (c: ^Compiled, err: Error) {
	if d == nil {
		return nil, make_error(.Bad_Option, "description", "nil description", allocator = allocator)
	}
	c = new(Compiled, allocator)
	if c == nil {
		return nil, make_error(.No_Memory, "", "out of memory", allocator = allocator)
	}
	c^ = {description = d, opts = opts, allocator = allocator}
	work := d
	asserted: rules.Description
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

// Frees all resources owned by `c` and `c` itself.
destroy :: proc(c: ^Compiled) {
	if c == nil {
		return
	}
	a := c.allocator
	check.plan_destroy(&c.plan)
	if c.owns_description && c.description != nil {
		rules.description_destroy(c.description)
		free(c.description, a)
	}
	resolver_destroy(&c.res)
	if c.owns_doc {
		tape.destroy_document(&c.doc)
	}
	free(c, a)
}

// Checks an already-built `tape.Document` against compiled schema `c`.
@(require_results)
check_document :: proc(c: ^Compiled, doc: ^tape.Document, sink: ^check.Sink = nil, allocator := context.allocator) -> check.Result {
	if c == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "compiled"}}
	}
	copts := check.Options{dups = c.opts.dups, budget = c.opts.budget}
	return check.check_document(doc, &c.plan, copts, sink, allocator)
}

// Convenience predicate: whether `doc` passes compiled schema `c`.
valid_document :: proc(c: ^Compiled, doc: ^tape.Document, allocator := context.allocator) -> bool {
	res := check_document(c, doc, nil, allocator)
	ok := res.valid
	check.result_destroy(&res)
	return ok
}

// Returns a shallow copy of `d` with `assert_format` enabled on non-foreign formats (both node and member rules) when `on` is true.
// When `on` is true, caller must call `asserting_destroy(&out, on, allocator)` unless `allocator` is an arena.
@(private)
asserting :: proc(d: ^rules.Description, on: bool, allocator: runtime.Allocator) -> rules.Description {
	out := d^
	if on {
		out.nodes = slice.clone_to_dynamic(d.nodes[:], allocator)
		for &n in out.nodes {
			n.rules.assert_format ||= !n.rules.format_foreign
		}
		out.objects = slice.clone_to_dynamic(d.objects[:], allocator)
		for &o in out.objects {
			if len(o.members) > 0 {
				o.members = slice.clone(o.members, allocator)
				for &m in o.members {
					m.rules.assert_format ||= !m.rules.format_foreign
				}
			}
		}
	}
	return out
}

@(private)
asserting_destroy :: proc(d: ^rules.Description, on: bool, allocator: runtime.Allocator) {
	if !on {
		return
	}
	delete(d.nodes)
	for o in d.objects {
		delete(o.members, allocator)
	}
	delete(d.objects)
}
