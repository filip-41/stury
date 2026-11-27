package jq

import "base:runtime"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/query"

// `css(selector)`: emits each matched markup element directly in O(1), building paths only when tracking.

@(private)
SELECTORS_CACHED :: 64

@(private)
Selector_Cache :: struct {
	allocator: runtime.Allocator,
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
	if reserve(&c.texts, len(c.texts) + 1) != nil || reserve(&c.selectors, len(c.selectors) + 1) != nil {
		return nil, query.fail(m.h, .Memory, .None)
	}
	made, err := css.compile(s, c.allocator)
	if err != nil {
		if f, is_fault := err.(tape.Fault); is_fault {
			return nil, raise_selector_fault(m, text, f)
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
	numeral: [20]u8
	append_all_str(&out, " (at offset ", strconv.write_int(numeral[:], i64(f.at), 10), ") is not a valid selector: ", tape.fault_rule(f).message)
	return raise_owned_text(m, string(out[:]))
}

@(private)
Css_Frame :: struct {
	using frame: Frame,
	doc:         query.Value,
	mat:         query.Value,
	path:        query.Value,
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
	start_node: tape.Node_Index
	markup := false
	mat_val := query.ABSENT
	moved_mat := false
	defer if !moved_mat {
		query.release(h, mat_val)
	}
	if r.input.kind == .Node {
		d, start_node = (^query.Doc_Block)(r.input.p), tape.Node_Index(r.input.n)
	} else if r.input.kind == .Overlay {
		mv, bd, bn, has_mat, oms := query.overlay_css_origin(h, r.input)
		if oms != .Ok {
			finish(m, r, .Fail)
			return
		}
		if has_mat {
			mat_val = mv
		}
		if bd != nil && bn != tape.NO_NODE {
			d, start_node = bd, bn
		}
	}
	if d != nil && m.hooks != nil && m.hooks.markup != nil {
		opts, markup = m.hooks.markup(m.hooks.data, &d.doc)
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
	found, err := css.select(&d.doc, start_node, sel, opts, query.heap_allocator(h))
	if err != nil {
		_ = query.fail(h, .Memory, .None)
		finish(m, r, .Fail)
		return
	}
	moved_found := false
	defer if !moved_found {
		css.destroy_found(&found)
	}
	if found.partial || len(found.matches) == 0 {
		h.tainted ||= found.partial
		finish(m, r, .Go)
		return
	}
	if r.track && !is_path(r.path) {
		_ = raise_taken(h, path_error(m, "Invalid path expression with result ", r.path))
		finish(m, r, .Fail)
		return
	}
	f := push_or_fail(m, r, Css_Frame, .Css)
	if f == nil {
		return
	}
	f.doc, f.mat, f.path, f.found, f.i = r.input, mat_val, r.path, found, 0
	moved_mat, moved_found = true, true
	r.input, r.path = query.ABSENT, query.ABSENT
	env_release(m, r.env)
	r.env = nil
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
	d: ^query.Doc_Block
	if f.mat.kind == .Node {
		d = (^query.Doc_Block)(f.mat.p)
	} else if f.doc.kind == .Overlay {
		_, d, _, _, _ = query.overlay_css_origin(h, f.doc)
	} else {
		d = (^query.Doc_Block)(f.doc.p)
	}
	v, s := query.node_at(h, d, match.value)
	vp := query.ABSENT
	if s == .Ok && f.track {
		vp, s = path_value(h, d, f.path, css.steps_of(&f.found, match))
	}
	if s != .Ok {
		query.release(h, v)
		drop_css(m, f)
		pop_frame(m)
		r.sig, r.mode = .Fail, .Ret
		return
	}
	r.v, r.vpath, r.k, r.mode = v, vp, f.k, .Emit
}

@(private)
drop_css :: proc(m: ^Machine, f: ^Css_Frame) {
	css.destroy_found(&f.found)
	query.release(m.h, f.mat)
	query.release(m.h, f.doc)
	query.release(m.h, f.path)
}

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
		query.append_owned(h, &path, query.key_value(h, d, step.key) or_return) or_return
		if step.index >= 0 {
			query.append_owned(h, &path, query.int_value(i64(step.index))) or_return
		}
	}
	return path, .Ok
}
