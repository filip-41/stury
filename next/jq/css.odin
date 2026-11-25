package jq

import "base:runtime"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/query"

// `css(selector)`, which the prelude writes as `_css_paths(selector)` over `getpath`: the paths of the elements of an XML
// input below the input's element that the selector matches, in document order, each a name and, for a name its parent
// repeats, the place among them. `getpath` reads and extends them, so `path`, `|=` and `del` go through it as through
// any path expression.

// The selectors a run compiled, kept by their text, so a call site that runs again compiles nothing. A run that
// compiles more than `SELECTORS_CACHED` starts the cache over.
@(private)
SELECTORS_CACHED :: 64

@(private)
Selector_Cache :: struct {
	allocator: runtime.Allocator, // the heap's, so the selectors count against the memory budget
	texts:     [dynamic]string,
	selectors: [dynamic]css.Selector,
}

@(private)
selector_cache_clear :: proc(c: ^Selector_Cache) {
	for text in c.texts {
		delete(text, c.allocator)
	}
	for &sel in c.selectors {
		css.destroy(&sel)
	}
	clear(&c.texts)
	clear(&c.selectors)
}

@(private)
selector_cache_destroy :: proc(c: ^Selector_Cache) {
	selector_cache_clear(c)
	delete(c.texts)
	delete(c.selectors)
	c^ = {}
}

// The compiled selector `text` is, from the cache or compiled now. One that is no selector list is an error that
// says where.
@(private)
compiled_selector :: proc(m: ^Machine, text: query.Value) -> (sel: ^css.Selector, status: query.Status) {
	c := &m.css
	s := query.text_of(text)
	for t, i in c.texts {
		if t == s {
			return &c.selectors[i], .Ok
		}
	}
	if c.allocator.procedure == nil {
		c.allocator = query.heap_allocator(m.h)
		c.texts = make([dynamic]string, c.allocator)
		c.selectors = make([dynamic]css.Selector, c.allocator)
	} else if len(c.texts) >= SELECTORS_CACHED {
		selector_cache_clear(c)
	}
	// The room for the entry is taken first, so a compiled selector is never left with nowhere to go.
	if reserve(&c.texts, len(c.texts) + 1) != nil || reserve(&c.selectors, len(c.selectors) + 1) != nil {
		return nil, query.fail(m.h, .Memory, .None)
	}
	made, err := css.compile(s, c.allocator)
	if err != nil {
		#partial switch e in err {
		case tape.Fault:
			return nil, raise_selector_fault(m, text, e)
		}
		return nil, query.fail(m.h, .Memory, .None)
	}
	own, cloned := strings.clone(s, c.allocator)
	if cloned != nil {
		css.destroy(&made)
		return nil, query.fail(m.h, .Memory, .None)
	}
	append(&c.texts, own)
	append(&c.selectors, made)
	return &c.selectors[len(c.selectors) - 1], .Ok
}

@(private = "file")
raise_selector_fault :: proc(m: ^Machine, text: query.Value, f: tape.Fault) -> query.Status {
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	write_brief(m.h, &out, text)
	append(&out, " (at offset ")
	numeral: [20]u8
	append(&out, strconv.write_int(numeral[:], i64(f.at), 10))
	append(&out, ") is not a valid selector: ")
	append(&out, tape.fault_rule(f).message)
	return raise_owned_text(m, string(out[:]))
}

// How a selector reads document `doc`, which the caller's `Hooks.markup` says, false for a document that is no markup, a
// partial one, and any when the caller gave no hook.
@(private = "file")
markup_options :: proc(m: ^Machine, doc: ^tape.Document) -> (opts: css.Options, ok: bool) {
	if m.hooks == nil || m.hooks.markup == nil || doc.partial != nil {
		return {}, false
	}
	return m.hooks.markup(m.hooks.data, doc)
}

// _css_paths(selector): an array of the paths of the elements below the input that the selector matches.
@(private)
v_css_paths :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	if !query.is_text(args[0]) {
		return query.NULL, raise_typed(m, args[0], " cannot be a selector, as it is not a string")
	}
	opts: css.Options
	d: ^query.Doc_Block
	markup := false
	if x.kind == .Node {
		d = (^query.Doc_Block)(x.p)
		opts, markup = markup_options(m, &d.doc)
	}
	if !markup {
		return query.NULL, raise_typed(m, x, " cannot be selected from, as it is not an element of an xml or html input")
	}
	sel := compiled_selector(m, args[0]) or_return
	found, err := css.select(&d.doc, tape.Node_Index(x.n), sel, opts, query.heap_allocator(h))
	if err != nil {
		return query.NULL, query.fail(h, .Memory, .None)
	}
	defer css.destroy_found(&found)
	out := query.make_array(h, len(found.matches)) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	for match in found.matches {
		path := path_value(h, d, css.steps_of(&found, match)) or_return
		query.append_owned(h, &out, path) or_return
	}
	return out, .Ok
}

// The path `steps` of document block `d` as an array of names and places.
@(private = "file")
path_value :: proc(h: ^query.Heap, d: ^query.Doc_Block, steps: []css.Step) -> (res: query.Value, status: query.Status) {
	path := query.make_array(h, len(steps)) or_return
	defer if status != .Ok {
		query.release(h, path)
	}
	for step in steps {
		name := query.key_value(h, d, step.key) or_return
		query.append_owned(h, &path, name) or_return
		if step.index >= 0 {
			query.append_owned(h, &path, query.int_value(i64(step.index))) or_return
		}
	}
	return path, .Ok
}
