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

// A compiled schema bound to a format: the plan that reads a text of it.
Bound :: struct {
	plan:     typed.Plan,
	compiled: ^Compiled,
}

// Binds `c` to the format `as`. A schema keyword the plan does not judge yet is refused as `.Unsupported`, naming it.
bind :: proc(c: ^Compiled, as: core.As, allocator := context.allocator) -> (b: Bound, err: core.Error) {
	if keyword := rules.unjudged(c.description, c.opts.format_assert); keyword != "" {
		return {}, core.error_of(core.Typed_Error{kind = .Unsupported, want = {text = keyword}})
	}
	b.compiled = c
	b.plan, err = typed.plan_of(c.description, as, nil, {}, allocator)
	return
}

unbind :: proc(b: ^Bound) {
	typed.plan_destroy(&b.plan)
	b^ = {}
}
