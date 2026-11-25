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

// How a selector reads document `doc`, which the caller's `Hooks.markup` says, false for a document that is no markup
// or when the caller gave no hook.
@(private = "file")
markup_options :: proc(m: ^Machine, doc: ^tape.Document) -> (opts: css.Options, ok: bool) {
	if m.hooks == nil || m.hooks.markup == nil {
		return {}, false
	}
	return m.hooks.markup(m.hooks.data, doc)
}

// Generator frame for `css(selector)`: holds the `css.Found` match list and emits each matched node directly in O(1),
// building its path only when `f.track` is set (`path(...)`, `|=`, `del(...)`).
@(private)
Css_Frame :: struct {
	using frame: Frame,
	doc:         query.Value, // held (keeps Doc_Block alive)
	path:        query.Value, // held (parent path when tracking)
	found:       css.Found,
	i:           int,
}

@(private)
start_css :: proc(m: ^Machine, r: ^Regs, sel_val: query.Value) {
	h := m.h
	if !query.is_text(sel_val) {
		_ = raise_typed(m, sel_val, " cannot be a selector, as it is not a string")
		finish(m, r, .Fail)
		return
	}
	opts: css.Options
	d: ^query.Doc_Block
	markup := false
	if r.input.kind == .Node {
		d = (^query.Doc_Block)(r.input.p)
		opts, markup = markup_options(m, &d.doc)
	}
	if !markup {
		_ = raise_typed(m, r.input, " cannot be selected from, as it is not an element of an xml or html input")
		finish(m, r, .Fail)
		return
	}
	sel, ss := compiled_selector(m, sel_val)
	if ss != .Ok {
		finish(m, r, .Fail)
		return
	}
	found, err := css.select(&d.doc, tape.Node_Index(r.input.n), sel, opts, query.heap_allocator(h))
	if err != nil {
		_ = query.fail(h, .Memory, .None)
		finish(m, r, .Fail)
		return
	}
	if found.partial {
		h.tainted = true
		css.destroy_found(&found)
		finish(m, r, .Go)
		return
	}
	if len(found.matches) == 0 {
		css.destroy_found(&found)
		finish(m, r, .Go)
		return
	}
	if r.track && !is_path(r.path) {
		css.destroy_found(&found)
		_ = raise_taken(h, path_error(m, "Invalid path expression with result ", r.path))
		finish(m, r, .Fail)
		return
	}
	doc := r.input
	parent_path := r.path
	k, track := r.k, r.track
	r.input, r.path = query.ABSENT, query.ABSENT
	env_release(m, r.env)
	r.env = nil
	f, ps := push(m, Css_Frame, .Css, k)
	if ps != .Ok {
		css.destroy_found(&found)
		query.release(h, doc)
		query.release(h, parent_path)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	f.track, f.doc, f.path, f.found, f.i = track, doc, parent_path, found, 0
	r.sig = .Go
	resume_css(m, r, f)
}

@(private)
resume_css :: proc(m: ^Machine, r: ^Regs, f: ^Css_Frame) {
	h := m.h
	if r.sig != .Go || f.i >= len(f.found.matches) {
		drop_css(m, f)
		pop_frame(m)
		return
	}
	match := f.found.matches[f.i]
	f.i += 1
	d := (^query.Doc_Block)(f.doc.p)
	v, s := query.node_at(h, d, match.value)
	if s != .Ok {
		drop_css(m, f)
		pop_frame(m)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	vp := query.ABSENT
	if f.track {
		vp, s = path_value(h, d, f.path, css.steps_of(&f.found, match))
		if s != .Ok {
			query.release(h, v)
			drop_css(m, f)
			pop_frame(m)
			r.sig, r.mode = .Fail, .Ret
			return
		}
	}
	r.v, r.vpath, r.k, r.mode = v, vp, f.k, .Emit
}

@(private)
drop_css :: proc(m: ^Machine, f: ^Css_Frame) {
	css.destroy_found(&f.found)
	query.release(m.h, f.doc)
	query.release(m.h, f.path)
}

// The path `steps` of document block `d`, appended after `prefix` (when it is an array), as an array of names and places.
@(private = "file")
path_value :: proc(h: ^query.Heap, d: ^query.Doc_Block, prefix: query.Value, steps: []css.Step) -> (res: query.Value, status: query.Status) {
	base_n := len(query.items_of(prefix)) if prefix.kind == .Array else 0
	path := query.make_array(h, base_n + len(steps)) or_return
	defer if status != .Ok {
		query.release(h, path)
	}
	if prefix.kind == .Array {
		for item in query.items_of(prefix) {
			query.append_owned(h, &path, query.retain(item)) or_return
		}
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
