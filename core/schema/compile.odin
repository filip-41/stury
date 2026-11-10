package schema

import "base:runtime"
import core "../"
import "../rules"
import "../typed"

// What a compile and its binds are made with.
Options :: struct {
	// Whether `format` asserts and does not only annotate.
	format_assert: bool,
	// The retrieval URI of the schema, "" for none.
	base:          string,
	// Where file references lead and how they are read, see `Resolver`.
	resolver:      Resolver,
}

// A schema read once and frozen: share it across threads and bind it to each format. It owns its description, unless
// it was made from one, and the documents its references loaded.
Compiled :: struct {
	description: ^rules.Description,
	opts:        Options,
	owned:       bool,
	allocator:   runtime.Allocator,
}

// Reads the schema at `node` of `doc` and indexes every container of the documents it borrows from, since a lazy index
// writes to a document a bind shares across threads. `doc` outlives the result.
compile :: proc(doc: ^core.Document, node: core.Node_Index, opts := Options{}, allocator := context.allocator) -> (c: Compiled, err: core.Error) {
	c = Compiled {
		opts      = opts,
		owned     = true,
		allocator = allocator,
	}
	c.description = new(rules.Description, allocator)
	c.description^, err = read(doc, node, opts.base, &c.opts.resolver, allocator)
	if err != nil {
		destroy(&c)
		return {}, err
	}
	for &n in c.description.nodes {
		n.rules.assert_format ||= opts.format_assert
	}
	index_all(doc)
	for d in c.opts.resolver.documents {
		index_all(d)
	}
	return
}

// A compiled schema of a description `d` made without a schema document. It borrows `d`, which outlives it.
compile_description :: proc(d: ^rules.Description, opts := Options{}, allocator := context.allocator) -> Compiled {
	return {description = d, opts = opts, allocator = allocator}
}

destroy :: proc(c: ^Compiled) {
	if c.owned && c.description != nil {
		rules.description_destroy(c.description)
		free(c.description, c.allocator)
	}
	resolver_destroy(&c.opts.resolver)
	c^ = {}
}

@(private)
index_all :: proc(doc: ^core.Document) {
	for _, i in doc.nodes {
		core.index_children(doc, core.Node_Index(i))
	}
}

// A compiled schema bound to a format: the plan a check of a text or a document of it reads with.
Bound :: struct {
	plan:     typed.Plan,
	compiled: ^Compiled,
}

// Binds `c` to the format `as`, whose check `reads` gives when it is set, as `typed.plan_of` takes it. A schema keyword
// the check does not judge yet is refused as `.Unsupported`, naming it, and a compile that failed as `.Bad_Option`.
bind :: proc(c: ^Compiled, as: core.As, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (b: Bound, err: core.Error) {
	if c == nil || c.description == nil {
		return {}, core.error_of(core.Typed_Error{kind = .Bad_Option})
	}
	if keyword := rules.unjudged(c.description); keyword != "" {
		return {}, core.error_of(core.Typed_Error{kind = .Unsupported, want = {text = keyword}})
	}
	b.compiled = c
	b.plan, err = typed.plan_of(c.description, as, reads, {checking = true}, allocator)
	return
}

// Checks `src`, one text of the format `b` is bound to, with every failure in `sink.entries`, and returns the first. With
// no sink the check stops at the first failure. A check allocates only the entries, with the sink's allocator.
check :: proc(b: ^Bound, src: []u8, sink: ^typed.Sink = nil) -> core.Error {
	if b.plan.check == nil {
		return core.error_of(core.Typed_Error{kind = .Plan_Mismatch})
	}
	target: u8
	return core.error_of(b.plan.check(src, b.plan.as, &target, nil, &b.plan, {sink = sink}, context.allocator))
}

// Whether `src` passes the schema, as `check` with no sink says.
valid :: proc(b: ^Bound, src: []u8) -> bool {
	return check(b, src) == nil
}

// Checks the value at `node` of `doc`, a document of the format `b` is bound to, as `check` checks a text.
check_node :: proc(b: ^Bound, doc: ^core.Document, node: core.Node_Index, sink: ^typed.Sink = nil) -> core.Error {
	target: u8
	return typed.check_document(doc, node, &target, nil, &b.plan, {sink = sink})
}

unbind :: proc(b: ^Bound) {
	typed.plan_destroy(&b.plan)
	b^ = {}
}
