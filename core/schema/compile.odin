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
	// How a key that repeats in an object is judged: the instance has the members `dups` reads, so a count, a rule for
	// the key and a `required` see one member under `.Last` or `.First`, and `.Refuse` refuses every repeat. `.All` is
	// `.Bad_Option` at a check.
	dups:          core.Duplicates,
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
	// Set when the root is an array checked entry by entry, which a check with a runner reads on its threads.
	elements:  ^Elements,
	allocator: runtime.Allocator,
}

// Binds `c` to the format `as`, whose check `reads` gives when it is set, as `typed.plan_of` takes it. A schema keyword
// the check does not judge is refused as `.Unsupported`, naming it, and a compile that failed as `.Bad_Option`.
bind :: proc(c: ^Compiled, as: core.As, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (b: Bound, err: core.Error) {
	if c == nil || c.description == nil {
		return {}, core.error_of(core.Typed_Error{kind = .Bad_Option})
	}
	b.compiled = c
	b.allocator = allocator
	b.plan, err = typed.plan_of(c.description, as, reads, {checking = true}, allocator)
	if err == nil {
		b.elements = elements_of(c, as, reads, allocator)
	}
	return
}

// Checks `src`, one text of the format `b` is bound to, with every failure in `sink.entries`, and returns the first. With
// no sink the check stops at the first failure. A check allocates the entries with the sink's allocator, and a schema
// with an applicator judges its arms beside the read in the temp allocator. A root
// array whose rules are per entry is checked on the threads of `runner` when one is given, with the same entries.
check :: proc(b: ^Bound, src: []u8, sink: ^typed.Sink = nil, runner: ^core.Runner = nil) -> core.Error {
	if b.plan.check == nil {
		return core.error_of(core.Typed_Error{kind = .Plan_Mismatch})
	}
	if parallel(b, runner) {
		if err, done := check_elements(b, src, sink, runner); done {
			return err
		}
	}
	target: u8
	return outcome(typed.check_text(src, &target, nil, &b.plan, read_of(b, sink)), sink)
}

// The options a check of `b` reads with: the schema's `dups`, and for a flat format's text, whose objects hold no repeat
// but a header's, no repeats noticed.
@(private)
read_of :: proc(b: ^Bound, sink: ^typed.Sink) -> typed.Read_Options {
	flat := b.plan.as.readers != nil && b.plan.as.readers.flat
	return {sink = sink, dups = b.compiled.opts.dups, repeats = .Ignore if flat else .Notice}
}

// `err`, the first failure of a check, unless the check ended on a fault, which outranks it and which a limit of the
// sink's entries does not hide.
@(private)
outcome :: proc(err: core.Error, sink: ^typed.Sink) -> core.Error {
	if sink != nil && sink.fatal.kind != .None {
		return core.error_of(sink.fatal)
	}
	return err
}

// The check of `plan` over the text `src`, for a plan that holds no record.
@(private)
check_text :: proc(plan: ^typed.Plan, src: []u8, read: typed.Read_Options) -> core.Typed_Error {
	target: u8
	return plan.check(src, plan.as, &target, nil, plan, read, context.allocator)
}

// Whether `src` passes the schema, as `check` with no sink says.
valid :: proc(b: ^Bound, src: []u8, runner: ^core.Runner = nil) -> bool {
	if parallel(b, runner) {
		if err, done := check_elements(b, src, nil, runner); done {
			return err == nil
		}
	}
	return check(b, src) == nil
}

// Whether a check of a root array can run on the threads of `runner`.
@(private)
parallel :: proc(b: ^Bound, runner: ^core.Runner) -> bool {
	return b.elements != nil && runner != nil && runner.threads > 0
}

// Checks the value at `node` of `doc`, a document of the format `b` is bound to, as `check` checks a text.
check_node :: proc(b: ^Bound, doc: ^core.Document, node: core.Node_Index, sink: ^typed.Sink = nil) -> core.Error {
	target: u8
	return typed.check_document(doc, node, &target, nil, &b.plan, {sink = sink})
}

unbind :: proc(b: ^Bound) {
	elements_destroy(b.elements, b.allocator)
	typed.plan_destroy(&b.plan)
	b^ = {}
}
