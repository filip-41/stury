package jq

import "core:fmt"
import "stury:lib/core/tape"
import "stury:lib/query"

// The builtins that tell what the linker was given: `get_search_list`, `get_jq_origin`, `get_prog_origin`, and
// `modulemeta`, which reads a module's directives as the linker would.

@(private)
v_module_info :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	mods := &m.prog.modules
	switch b.name {
	case "get_jq_origin":
		return query.text_value(m.h, mods.jq_origin)
	case "get_prog_origin":
		return query.text_value(m.h, mods.origin)
	}
	out := query.make_array(m.h, len(mods.search)) or_return
	for dir in mods.search {
		t, s := query.text_value(m.h, dir)
		if s == .Ok {
			s = query.append_owned(m.h, &out, t)
		}
		if s != .Ok {
			query.release(m.h, out)
			return query.NULL, s
		}
	}
	return out, .Ok
}

// The module the input names, found on `Modules.search` alone: its `module` metadata, with its directives as `deps`
// and the names of its definitions as `defs`. A module that does not parse gives null, its errors sent to `stderr`.
@(private)
v_modulemeta :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	if !query.is_text(x) {
		return query.NULL, raise_text(m, "modulemeta input module name must be a string")
	}
	u: Unit
	unit_init(&u, m.h.allocator)
	defer unit_destroy(&u)
	context.allocator = u.allocator
	mods := &m.prog.modules
	path, text, msg := find_module(mods, query.text_of(x), mods.search, ".jq", "")
	if msg != "" {
		return query.NULL, raise_owned_text(m, msg)
	}
	errors := make([dynamic]Compile_Error)
	prog := parse_library(&u, text, path, &errors, tape.DEFAULT_DEPTH)
	if len(errors) > 0 {
		for e in errors {
			report_to_stderr(m, fmt.aprintf("jq: error: %s\n", locate(e)))
		}
		return query.NULL, .Ok
	}
	meta := module_meta(&u, prog) or_return
	out := make([dynamic]u8)
	if s := query.write_json(&u.heap, &out, meta); s != .Ok {
		query.clear_error(&u.heap)
		return query.NULL, s
	}
	return read_json(m, string(out[:]))
}

// `prog`'s metadata object with `deps` and `defs` added, in the unit's heap.
@(private = "file")
module_meta :: proc(u: ^Unit, prog: Parsed) -> (meta: query.Value, status: query.Status) {
	h := &u.heap
	meta = query.make_object(h, 4) or_return
	if prog.meta.kind == .Object {
		for e in query.entries_of(prog.meta) {
			query.object_put(h, &meta, e.key, query.retain(e.value)) or_return
		}
	}
	deps := query.make_array(h, len(prog.deps)) or_return
	for d in prog.deps {
		query.append_owned(h, &deps, d) or_return
	}
	defs := query.make_array(h, 4) or_return
	seen := make(map[string]bool)
	for d := prog.defs; d != nil; d = d.a {
		sig := fmt.aprintf("%s/%d", d.fn.name, len(d.fn.params))
		if !seen[sig] {
			seen[sig] = true
			query.append_owned(h, &defs, query.text_value(h, sig) or_return) or_return
		}
	}
	query.object_put(h, &meta, query.text_borrowed("deps"), deps) or_return
	query.object_put(h, &meta, query.text_borrowed("defs"), defs) or_return
	return meta, .Ok
}

@(private = "file")
report_to_stderr :: proc(m: ^Machine, line: string) {
	if m.hooks == nil || m.hooks.stderr == nil {
		return
	}
	t, s := query.text_value(m.h, line)
	if s != .Ok {
		query.clear_error(m.h)
		return
	}
	m.hooks.stderr(m.hooks.data, t, m.h)
	query.release(m.h, t)
}
