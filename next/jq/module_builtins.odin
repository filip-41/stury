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
	return module_meta(m.h, prog)
}

// `prog`'s metadata object with `deps` and `defs` added, copied directly into `h`.
@(private = "file")
module_meta :: proc(h: ^query.Heap, prog: Parsed) -> (meta: query.Value, status: query.Status) {
	meta = query.make_object(h, 4) or_return
	defer if status != .Ok {
		query.release(h, meta)
	}
	if prog.meta.kind == .Object {
		for e in query.entries_of(prog.meta) {
			k := query.text_value(h, query.text_of(e.key)) or_return
			v, vs := query.built_deep(h, e.value)
			if vs != .Ok {
				query.release(h, k)
				return query.NULL, vs
			}
			query.object_put(h, &meta, k, v) or_return
		}
	}
	deps := query.make_array(h, len(prog.deps)) or_return
	for d in prog.deps {
		v, vs := query.built_deep(h, d)
		if vs != .Ok {
			query.release(h, deps)
			return query.NULL, vs
		}
		if s := query.append_owned(h, &deps, v); s != .Ok {
			query.release(h, deps)
			return query.NULL, s
		}
	}
	query.object_put(h, &meta, query.text_borrowed("deps"), deps) or_return
	defs := query.make_array(h, 4) or_return
	seen := make(map[string]bool)
	for d := prog.defs; d != nil; d = d.a {
		sig := fmt.aprintf("%s/%d", d.fn.name, len(d.fn.params))
		if !seen[sig] {
			seen[sig] = true
			t, ts := query.text_value(h, sig)
			if ts != .Ok {
				query.release(h, defs)
				return query.NULL, ts
			}
			if s := query.append_owned(h, &defs, t); s != .Ok {
				query.release(h, defs)
				return query.NULL, s
			}
		}
	}
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
