package cli

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "stury:engine"
import "stury:host"
import "stury:jq"
import "stury:jsonpath"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/ops/write"
import "stury:lib/query"
import "stury:lib/schema/rules"
import "stury:lib/schema/schema"

MAX_FILES_PARALLEL_BYTES :: 128 * 1024 * 1024

@(private = "file")
Order_Key :: struct {
	file_idx: int,
	rec_idx:  u64,
}

@(private = "file")
Preloaded_Var :: struct {
	name:       string,
	kind:       Var_Kind,
	raw_text:   string,
	raw_owned:  bool,
	has_doc:    bool,
	doc:        tape.Document,
	slurp_docs: []tape.Document,
}

@(private = "file")
Preloaded_Pos :: struct {
	raw_text: string,
	is_json:  bool,
	has_doc:  bool,
	doc:      tape.Document,
}

// Deterministic outcome tracker shared safely across parallel workers by `(file_idx, rec_idx)`.
@(private = "file")
Merge_State :: struct {
	total_emitted: u64,
	has_last:      bool,
	last_key:      Order_Key,
	last_falsy:    bool,
	has_err:       bool,
	err_key:       Order_Key,
	err_kind:      engine.Exec_Error,
	halt_code:     int,
	err_msg:       string,
	halt_msg:      string,
	nul_err:       bool,
}

@(private = "file")
Direct_Tab_Sink :: struct {
	osink:             ^Out_Stream,
	suppress_next_hdr: bool,
}

// Immutable per-run shared state prepared ONCE on the parent thread before any workers run.
Shared_Jq_State :: struct {
	o:                 ^Options,
	cfg:               ^Render_Config,
	main_prog:         ^jq.Program,
	ident_prog:        ^jq.Program,
	stream_prog:       ^jq.Program,
	each_prog:         ^jq.Program,
	pred_prog:         ^jq.Program,
	tail_prog:         ^jq.Program,
	used_globals:      []bool,
	ident_main:        bool,
	fast_json:         engine.Fast_Json_Mode,
	compact_cfg:       Render_Config,
	env_entries:       []string,
	vars:              []Preloaded_Var,
	pos:               []Preloaded_Pos,
	aux_srcs:          [][]u8,
	aux_set:           engine.Aux_Set,
	has_aux:           bool,
	zones:             Zone_Cache,
	needs_overlay:     bool,
	where_mode:        bool,
	collect_each:      bool,
	budget:            tape.Budget,
	osink:             ^Out_Stream,
	serial_worker:     ^Jq_Worker,
	direct_tab:        Direct_Tab_Sink,
	direct_tab_bytes:  u64,
	direct_tab_active: bool,
	stderr_w:          io.Writer,
	stderr_lock:       sync.Mutex,
	alloc:             runtime.Allocator,
	alloc_lock:        sync.Mutex,
	locked_alloc:      runtime.Allocator,
	pool_lock:         sync.Mutex,
	free_workers:      [dynamic]^Jq_Worker,
	merge_lock:        sync.Mutex,
	merge:             Merge_State,
	xml_schema_desc:   ^rules.Description,
}

// Per-worker/serial input cursor supporting multi-file streaming and persistent record iteration.
@(private = "file")
Hook_Ctx :: struct {
	o:              ^Options,
	paths:          []string,
	stdin_override: Maybe([]u8),
	file_idx:       int,
	file_path:      string,
	line_number:    i64,
	raw_lines:      bool,
	raw_stream:     Byte_Stream,
	stream_open:    bool,
	file_buf:       []u8,
	file_buf_owned: bool,
	cur_spec:       engine.Spec,
	cur_framing:    engine.Framing,
	cur_tabular:    bool,
	dsv_header:     []u8,
	recs_open:      bool,
	rec_loop:       Rec_Loop,
	single_done:    bool,
	has_open_err:   bool,
	stream_prog:    ^jq.Program,
	stream_heap:    ^query.Heap,
	stream_events:  [dynamic]query.Value,
	stream_idx:     int,
	runner:          ^tape.Runner,
	xml_schema_desc: ^rules.Description,
	stderr_w:        io.Writer,
	alloc:           runtime.Allocator,
}

Jq_Worker :: struct {
	shared:        ^Shared_Jq_State,
	hooks:         jq.Hooks,
	hook_ctx:      Hook_Ctx,
	h:             query.Heap,
	run:           jq.Run,
	each_run:      jq.Run,
	pred_run:      jq.Run,
	has_each_run:  bool,
	has_pred_run:  bool,
	globals:       []query.Value,
	scratch:       [dynamic]u8,
	where_sb:      strings.Builder,
	tw:            ^write.Table_Writer,
	rtw:           ^Render_Table_Writer,
	file_name:     string,
	err_msg:       string,
	halt_msg:      string,
	has_halt:      bool,
	halt_code:     int,
	last_falsy:    bool,
	out_count:     u64,
	nul_err:       bool,
	is_exclusive:  bool,
	alloc:         runtime.Allocator,
}

// Buffered `io.Writer` adapter writing directly into any `engine.Emitter` in 32 KiB stack chunks.
@(private = "file")
Emit_Writer :: struct {
	emit:      engine.Emitter,
	buf:       [STREAM_CHUNK_FLUSH]u8,
	cursor:    int,
	last_byte: u8,
	wrote_any: bool,
	stopped:   bool,
}

emit_writer_init :: proc(ew: ^Emit_Writer, emit: engine.Emitter) {
	ew^ = {
		emit = emit,
	}
}

emit_writer_flush :: proc(ew: ^Emit_Writer) -> bool {
	if ew.stopped {
		return false
	}
	if ew.cursor > 0 {
		data := ew.buf[:ew.cursor]
		ew.cursor = 0
		if !engine.emit_bytes(ew.emit, data) {
			ew.stopped = true
			return false
		}
	}
	return true
}

emit_writer_io :: proc(ew: ^Emit_Writer) -> io.Writer {
	stream_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		w := (^Emit_Writer)(data)
		#partial switch mode {
		case .Query:
			return io.query_utility({.Write, .Flush})
		case .Write:
			if w.stopped {
				return 0, .Unexpected_EOF
			}
			rem := p
			for len(rem) > 0 {
				space := len(w.buf) - w.cursor
				if space == 0 {
					if !emit_writer_flush(w) {
						return 0, .Unexpected_EOF
					}
					space = len(w.buf)
				}
				if w.cursor == 0 && len(rem) >= len(w.buf) {
					w.last_byte = rem[len(rem) - 1]
					w.wrote_any = true
					if !engine.emit_bytes(w.emit, rem) {
						w.stopped = true
						return 0, .Unexpected_EOF
					}
					return i64(len(p)), .None
				}
				take := min(space, len(rem))
				copy(w.buf[w.cursor:], rem[:take])
				w.cursor += take
				w.last_byte = rem[take - 1]
				w.wrote_any = true
				rem = rem[take:]
			}
			return i64(len(p)), .None
		case .Flush:
			if !emit_writer_flush(w) {
				return 0, .Unexpected_EOF
			}
			return 0, .None
		}
		return 0, .Empty
	}
	return io.Writer{procedure = stream_proc, data = ew}
}

@(private = "file")
key_lt :: proc "contextless" (a, b: Order_Key) -> bool {
	return a.file_idx < b.file_idx || (a.file_idx == b.file_idx && a.rec_idx < b.rec_idx)
}

@(private = "file")
key_ge :: proc "contextless" (a, b: Order_Key) -> bool {
	return !key_lt(a, b)
}

build_doc_val :: proc(
	h: ^query.Heap,
	bytes: []u8,
	sp: engine.Spec,
	ro: tape.Options,
	alloc: runtime.Allocator,
	owns_src := false,
	xml_arrays := tape.Xml_Arrays.Auto,
	xml_desc: ^rules.Description = nil,
) -> (val: query.Value, berr: tape.Error, mem_ok: bool) {
	doc, err := engine.build(bytes, sp, ro, alloc)
	if err != nil {
		return query.NULL, err, true
	}
	if xml_arrays == .Schema && xml_desc != nil {
		if e, ok := engine.entry_of_spec(sp); ok && e.family == .Xml {
			if nerr := engine.apply_xml_arrays(&doc, .Schema, xml_desc, alloc); nerr != nil {
				tape.destroy_document(&doc)
				return query.NULL, nerr, true
			}
		}
	}
	if owns_src {
		doc.flags += {.Owns_Src}
	}
	dv, ds := query.document_value(h, doc, owned = true)
	if ds != .Ok {
		if owns_src {
			doc.flags -= {.Owns_Src}
		}
		tape.destroy_document(&doc)
		return query.NULL, nil, false
	}
	return dv, nil, true
}

@(private = "file")
parse_json_for_jq :: proc(_: rawptr, src: []u8, budget: tape.Budget, alloc: runtime.Allocator) -> (tape.Document, tape.Error) {
	return engine.build(src, engine.spec_of_id(.Json), {budget = budget}, alloc)
}

@(private = "file")
markup_opts_for_jq :: proc(_: rawptr, doc: ^tape.Document) -> (css.Options, bool) {
	if doc != nil && doc.format != nil && doc.format.attribute != nil {
		return {attribute = doc.format.attribute}, true
	}
	return {}, false
}

@(private = "file")
mod_read_hook :: proc(_: rawptr, path: string, alloc: runtime.Allocator) -> (string, bool) {
	b, ok := read_path_or_stdin(path, false, io.Writer{}, alloc)
	return string(b), ok
}

@(private = "file")
locked_alloc_fn :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	sh := (^Shared_Jq_State)(data)
	sync.mutex_guard(&sh.alloc_lock)
	return sh.alloc.procedure(sh.alloc.data, mode, size, alignment, old_ptr, old_size, loc)
}

@(private = "file")
is_thread_safe_heap :: proc(a: runtime.Allocator) -> bool {
	return a.procedure == runtime.heap_allocator().procedure
}

@(private = "file")
format_arg_parse_err :: proc(label: string, src: []u8, err: tape.Error, alloc: runtime.Allocator) -> string {
	sb := strings.builder_make(alloc)
	if err != nil {
		err_buf: [512]u8
		snip_buf: [1024]u8
		at, msg, snip, has_place := tape_error_parts(src, err, engine.spec_of_id(.Json), &err_buf, &snip_buf)
		if has_place && len(src) > 0 {
			pl := tape.offset_place(src, nil, at)
			fmt.sbprintf(&sb, "%s (%d:%d: %s)", label, pl.line, pl.col, msg)
			if snip != "" {
				strings.write_byte(&sb, '\n')
				strings.write_string(&sb, strings.trim_right(snip, "\n"))
			}
			return strings.to_string(sb)
		}
	}
	strings.write_string(&sb, label)
	return strings.to_string(sb)
}

shared_jq_init :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	prog: ^jq.Program,
	plan: ^jq.Plan,
	osink: ^Out_Stream,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> (sh: ^Shared_Jq_State, err: string) {
	sh = new(Shared_Jq_State, alloc)
	sh^ = {
		o             = o,
		cfg           = cfg,
		main_prog     = prog,
		used_globals  = jq.used_globals_of(prog, alloc),
		ident_main    = jq.is_identity(prog),
		compact_cfg   = {
			compact   = true,
			raw0      = false,
			ascii     = false,
			sort_keys = false,
			colors    = DEFAULT_COLORS,
		},
		needs_overlay = plan.sources[.Main].facts || (o.has_to && (o.to_name == "xml" || o.to_name == "jsonc" || strings.has_prefix(o.to_name, "toml"))),
		where_mode    = o.where_mode,
		collect_each  = plan.hints.split.kind == .Collect,
		budget        = o.budget,
		osink         = osink,
		stderr_w      = stderr_w,
		alloc         = alloc,
	}
	if !o.raw && !o.join && !o.raw0 && !o.sort_keys && !o.ascii && !cfg.color && !o.seq && !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.where_mode && !o.exit_status && !o.skip_bad && o.budget == {} {
		if o.compact {
			sh.fast_json = .Compact
		} else if !o.tab && o.indent == 2 {
			sh.fast_json = .Pretty2
		}
	}
	sh.locked_alloc = alloc if is_thread_safe_heap(alloc) else runtime.Allocator{procedure = locked_alloc_fn, data = sh}
	sh.free_workers = make([dynamic]^Jq_Worker, sh.locked_alloc)
	zone_cache_init(&sh.zones, sh.locked_alloc)

	if o.stream {
		sp, serrs := jq.compile("tostream", {}, alloc)
		if len(serrs) == 0 {
			sh.stream_prog = sp
		} else {
			jq.destroy_program(sp)
		}
	}

	need_ident := ((plan.hints.split.kind == .Stream || plan.hints.split.kind == .Collect) && !plan.hints.split.has_each) ||
		(plan.hints.split.kind == .Collect && (!plan.hints.split.has_tail || plan.tail_body == nil))
	if need_ident {
		ip, ierrs := jq.compile(".", {}, alloc)
		if len(ierrs) == 0 {
			sh.ident_prog = ip
		} else {
			jq.destroy_program(ip)
		}
	}

	need_each := plan.hints.split.kind == .Stream || plan.hints.split.kind == .Collect || (plan.hints.split.kind == .Length && plan.hints.split.has_each)
	if need_each && (!plan.hints.split.has_each || plan.each_body != nil) {
		if plan.hints.split.has_each {
			ep := new_clone(prog^, alloc)
			ep.body = plan.each_body
			sh.each_prog = ep
		} else if sh.ident_prog != nil {
			ep := new_clone(sh.ident_prog^, alloc)
			sh.each_prog = ep
		}
	}
	if plan.hints.split.kind == .Collect {
		if plan.hints.split.has_tail && plan.tail_body != nil {
			tp := new_clone(prog^, alloc)
			tp.body = plan.tail_body
			sh.tail_prog = tp
		} else if sh.ident_prog != nil {
			tp := new_clone(sh.ident_prog^, alloc)
			sh.tail_prog = tp
		}
	}
	if plan.hints.conditional.active && plan.hints.conditional.cmp.op == .None && plan.pred_body != nil {
		pp := new_clone(prog^, alloc)
		pp.body = plan.pred_body
		sh.pred_prog = pp
	}

	if len(sh.used_globals) == 0 || sh.used_globals[0] {
		if ev, ev_err := os.environ(alloc); ev_err == nil {
			sh.env_entries = ev
		}
	}

	sh.vars = make([]Preloaded_Var, len(o.vars), alloc)
	for vs, i in o.vars {
		pv := Preloaded_Var{name = vs.name, kind = vs.kind}
		switch vs.kind {
		case .Arg:
			pv.raw_text = vs.raw
		case .Arg_Json:
			raw_b := transmute([]u8)vs.raw
			doc, derr := engine.build(raw_b, engine.spec_of_id(.Json), {budget = o.budget}, alloc)
			if derr != nil {
				sh.vars[i] = pv
				shared_jq_destroy(sh)
				lbl := fmt.aprintf("invalid JSON text passed to --argjson: %s", vs.raw, allocator = alloc)
				defer delete(lbl, alloc)
				return nil, format_arg_parse_err(lbl, raw_b, derr, alloc)
			}
			pv.doc = doc
			pv.has_doc = true
		case .Raw_File:
			data, rerr := os.read_entire_file_from_path(vs.raw, alloc)
			if rerr != nil {
				sh.vars[i] = pv
				shared_jq_destroy(sh)
				return nil, fmt.aprintf("--rawfile %s %s: Could not open %s: %s", vs.name, vs.raw, vs.raw, os.error_string(rerr), allocator = alloc)
			}
			pv.raw_text = string(data)
			pv.raw_owned = true
		case .Slurp_File:
			data, rerr := os.read_entire_file_from_path(vs.raw, alloc)
			if rerr != nil {
				sh.vars[i] = pv
				shared_jq_destroy(sh)
				return nil, fmt.aprintf("--slurpfile %s %s: Could not open %s: %s", vs.name, vs.raw, vs.raw, os.error_string(rerr), allocator = alloc)
			}
			pv.raw_text = string(data)
			pv.raw_owned = true
			docs := make([dynamic]tape.Document, alloc)
			it, ok := rec_loop_open(data, engine.spec_of_id(.Json), .Concatenated, {budget = o.budget}, false, vs.raw, io.Writer{}, alloc)
			if !ok {
				open_e := it.open_err
				delete(docs)
				sh.vars[i] = pv
				lbl := fmt.aprintf("parse error in --slurpfile %s", vs.raw, allocator = alloc)
				defer delete(lbl, alloc)
				msg := format_arg_parse_err(lbl, data, open_e, alloc)
				shared_jq_destroy(sh)
				return nil, msg
			}
			bad_slurp := false
			bad_err: tape.Error
			bad_src: []u8 = data
			for rec, _, rec_err in rec_loop_next(&it) {
				if rec_err != nil {
					bad_slurp = true
					bad_err = rec_err
					bad_src = data
					break
				}
				doc, berr := engine.build(rec, engine.spec_of_id(.Json), {budget = o.budget}, alloc)
				if berr != nil {
					bad_slurp = true
					bad_err = berr
					bad_src = rec
					break
				}
				append(&docs, doc)
			}
			if !bad_slurp && it.tail_err != nil {
				bad_slurp = true
				bad_err = it.tail_err
				bad_src = data
			}
			rec_loop_close(&it)
			if bad_slurp {
				for &d in docs {
					tape.destroy_document(&d)
				}
				delete(docs)
				sh.vars[i] = pv
				lbl := fmt.aprintf("parse error in --slurpfile %s", vs.raw, allocator = alloc)
				defer delete(lbl, alloc)
				msg := format_arg_parse_err(lbl, bad_src, bad_err, alloc)
				shared_jq_destroy(sh)
				return nil, msg
			}
			pv.slurp_docs = docs[:]
		}
		sh.vars[i] = pv
	}

	sh.pos = make([]Preloaded_Pos, len(o.positional), alloc)
	for ps, i in o.positional {
		pp := Preloaded_Pos{raw_text = ps.raw, is_json = ps.is_json}
		if ps.is_json {
			raw_b := transmute([]u8)ps.raw
			doc, derr := engine.build(raw_b, engine.spec_of_id(.Json), {budget = o.budget}, alloc)
			if derr != nil {
				sh.pos[i] = pp
				shared_jq_destroy(sh)
				lbl := fmt.aprintf("invalid JSON for --jsonargs: %s", ps.raw, allocator = alloc)
				defer delete(lbl, alloc)
				return nil, format_arg_parse_err(lbl, raw_b, derr, alloc)
			}
			pp.doc = doc
			pp.has_doc = true
		}
		sh.pos[i] = pp
	}
	return sh, ""
}

shared_jq_destroy :: proc(sh: ^Shared_Jq_State) {
	if sh == nil {
		return
	}
	a := sh.alloc
	for w in sh.free_workers {
		free_jq_worker(w)
	}
	delete(sh.free_workers)
	if sh.has_aux {
		engine.destroy_aux_set(&sh.aux_set)
		sh.has_aux = false
	}
	for b in sh.aux_srcs {
		delete(b, a)
	}
	delete(sh.aux_srcs, a)
	for &pv in sh.vars {
		if pv.has_doc {
			tape.destroy_document(&pv.doc)
		}
		for &sd in pv.slurp_docs {
			tape.destroy_document(&sd)
		}
		delete(pv.slurp_docs, a)
		if pv.raw_owned {
			delete(pv.raw_text, a)
		}
	}
	delete(sh.vars, a)
	for &pp in sh.pos {
		if pp.has_doc {
			tape.destroy_document(&pp.doc)
		}
	}
	delete(sh.pos, a)
	for e in sh.env_entries {
		delete(e, a)
	}
	delete(sh.env_entries, a)
	if sh.merge.err_msg != "" {
		delete(sh.merge.err_msg, a)
	}
	if sh.merge.halt_msg != "" {
		delete(sh.merge.halt_msg, a)
	}
	free(sh.each_prog, a)
	free(sh.pred_prog, a)
	free(sh.tail_prog, a)
	jq.destroy_program(sh.stream_prog)
	jq.destroy_program(sh.ident_prog)
	delete(sh.used_globals, a)
	zone_cache_destroy(&sh.zones)
	free(sh, a)
}

@(private = "file")
load_shared_aux :: proc(
	sh: ^Shared_Jq_State,
	o: ^Options,
	plan: ^query.Plan,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> int {
	n := len(o.with_sources)
	if n == 0 {
		return EXIT_OK
	}
	srcs := make([][]u8, n, alloc)
	aux_list := make([]engine.Aux_Source, n, alloc)
	defer delete(aux_list, alloc)

	for ws, i in o.with_sources {
		data, rok := read_path_or_stdin(ws.path, false, stderr_w, alloc)
		if !rok {
			for k in 0 ..< i {
				delete(srcs[k], alloc)
			}
			delete(srcs, alloc)
			return EXIT_USAGE
		}
		srcs[i] = data
		sp: engine.Spec
		fr: engine.Framing
		if ws.has_fmt {
			sp, fr = ws.spec, ws.framing
		} else if fe, ffr, ok := engine.format_of_path(ws.path); ok {
			sp, fr = fe.spec, ffr
		} else {
			sp, fr = engine.spec_of_id(.Json), .Single
		}
		if o.merge_keys && sp == engine.spec_of_id(.Yaml) {
			sp = engine.spec_of_id(.Yaml_Merge)
		}
		ro := read_opts_of(o, sp, nil)
		aux_list[i] = {
			name    = ws.name,
			src     = data,
			spec    = sp,
			opts    = ro,
			framing = fr,
		}
	}

	sh.aux_srcs = srcs
	aux_set, lres := engine.load_aux_sources(plan, aux_list, alloc)
	if lres.err != .None {
		fail_idx := 0
		for ws, i in o.with_sources {
			if ws.name == lres.failed {
				fail_idx = i
				break
			}
		}
		fws := o.with_sources[fail_idx]
		if lres.read_err != nil {
			_ = print_tape_error(stderr_w, fws.path, lres.read_err, srcs[fail_idx], aux_list[fail_idx].spec)
		} else if stderr_w.procedure != nil {
			fmt.wprintf(stderr_w, "stury: error: failed to load --with %s=%s\n", fws.name, fws.path)
		}
		return EXIT_RUNTIME
	}
	sh.aux_set = aux_set
	sh.has_aux = true
	return EXIT_OK
}

@(private = "file")
global_needed :: #force_inline proc "contextless" (used: []bool, idx: int) -> bool {
	return len(used) == 0 || (idx < len(used) && used[idx])
}

build_globals_from_shared :: proc(h: ^query.Heap, prog: ^jq.Program, sh: ^Shared_Jq_State, alloc: runtime.Allocator) -> ([]query.Value, bool) {
	globals := make([]query.Value, len(prog.globals), alloc)
	for &g in globals {
		g = query.NULL
	}
	ok := false
	defer if !ok {
		for g in globals {
			query.release(h, g)
		}
		delete(globals, alloc)
	}

	// Slot 0: `$ENV` populated ONLY when referenced by the filter.
	if global_needed(sh.used_globals, 0) {
		if env_obj, eok := query.make_object(h, len(sh.env_entries)); eok == .Ok {
			env_ok := true
			for entry in sh.env_entries {
				eq := strings.index_byte(entry, '=')
				k := entry[:eq] if eq >= 0 else entry
				v := entry[eq + 1:] if eq >= 0 else ""
				ks, s1 := query.text_value(h, k)
				vs, s2 := query.text_value(h, v)
				if s1 != .Ok || s2 != .Ok {
					query.release(h, ks)
					query.release(h, vs)
					env_ok = false
					break
				}
				if query.object_put(h, &env_obj, ks, vs) != .Ok {
					env_ok = false
					break
				}
			}
			if env_ok {
				globals[0] = env_obj
			} else {
				query.release(h, env_obj)
				return nil, false
			}
		} else {
			return nil, false
		}
	}

	args_slot := -1
	build_cfg_slot := -1
	need_any_var := false
	for name, idx in prog.globals {
		if !global_needed(sh.used_globals, idx) {
			continue
		}
		if name == "ARGS" {
			args_slot = idx
		} else if name == "JQ_BUILD_CONFIGURATION" {
			build_cfg_slot = idx
		} else if idx >= 2 {
			need_any_var = true
		}
	}
	need_prog_args := global_needed(sh.used_globals, 1)

	prog_args := query.ABSENT
	named_obj := query.ABSENT
	defer {
		if prog_args.kind != .Absent {
			query.release(h, prog_args)
		}
		if named_obj.kind != .Absent {
			query.release(h, named_obj)
		}
	}
	if need_prog_args || args_slot >= 0 {
		ps: query.Status
		prog_args, ps = query.make_array(h, len(sh.pos))
		if ps != .Ok {
			return nil, false
		}
		for pp in sh.pos {
			v: query.Value
			st: query.Status
			if pp.is_json {
				v, st = query.document_value(h, pp.doc, owned = false)
			} else {
				v, st = query.text_value(h, pp.raw_text)
			}
			if st != .Ok || query.append_owned(h, &prog_args, v) != .Ok {
				return nil, false
			}
		}
		if need_prog_args {
			globals[1] = query.retain(prog_args)
		}
	}
	if args_slot >= 0 {
		ns: query.Status
		named_obj, ns = query.make_object(h, len(sh.vars))
		if ns != .Ok {
			return nil, false
		}
	}

	if need_any_var || args_slot >= 0 {
		for pv in sh.vars {
			slot := -1
			for name, idx in prog.globals {
				if idx >= 2 && name == pv.name {
					slot = idx
					break
				}
			}
			if slot < 0 {
				continue
			}
			if args_slot < 0 && !global_needed(sh.used_globals, slot) {
				continue
			}
			val: query.Value
			st := query.Status.Ok
			switch pv.kind {
			case .Arg, .Raw_File:
				val, st = query.text_value(h, pv.raw_text)
			case .Arg_Json:
				val, st = query.document_value(h, pv.doc, owned = false)
			case .Slurp_File:
				val, st = query.make_array(h, len(pv.slurp_docs))
				if st == .Ok {
					for sd in pv.slurp_docs {
						dv, dst := query.document_value(h, sd, owned = false)
						if dst != .Ok || query.append_owned(h, &val, dv) != .Ok {
							query.release(h, val)
							val = query.NULL
							st = .Error
							break
						}
					}
				}
			}
			if st != .Ok {
				return nil, false
			}
			if global_needed(sh.used_globals, slot) && (globals[slot].kind == .Null || globals[slot].kind == .Absent) {
				query.release(h, globals[slot])
				globals[slot] = query.retain(val)
			}
			if named_obj.kind != .Absent {
				if ex, _ := query.member(h, named_obj, pv.name); ex.kind == .Absent {
					if ks, kok := query.text_value(h, pv.name); kok == .Ok {
						_ = query.object_put(h, &named_obj, ks, query.retain(val))
					}
				} else {
					query.release(h, ex)
				}
			}
			query.release(h, val)
		}
	}

	if sh.has_aux && need_any_var {
		for &b in sh.aux_set.bindings {
			slot := -1
			for name, idx in prog.globals {
				if idx >= 2 && name == b.name {
					slot = idx
					break
				}
			}
			if slot < 0 || !global_needed(sh.used_globals, slot) {
				continue
			}
			val, st := engine.aux_binding_to_value(&b, h)
			if st != .Ok {
				return nil, false
			}
			query.release(h, globals[slot])
			globals[slot] = val
		}
	}

	if args_slot >= 0 {
		args_obj, as := query.make_object(h, 2)
		if as != .Ok {
			return nil, false
		}
		if k1, s1 := query.text_value(h, "positional"); s1 == .Ok {
			_ = query.object_put(h, &args_obj, k1, query.retain(prog_args))
		}
		if k2, s2 := query.text_value(h, "named"); s2 == .Ok {
			_ = query.object_put(h, &args_obj, k2, query.retain(named_obj))
		}
		query.release(h, globals[args_slot])
		globals[args_slot] = args_obj
	}
	if build_cfg_slot >= 0 {
		if bv, bs := query.text_value(h, BUILD_CONFIG); bs == .Ok {
			query.release(h, globals[build_cfg_slot])
			globals[build_cfg_slot] = bv
		}
	}
	ok = true
	return globals, true
}

@(private = "file")
hook_msg :: proc(sh: ^Shared_Jq_State, v: query.Value, h: ^query.Heap, is_debug: bool) {
	if sh.stderr_w.procedure == nil {
		return
	}
	buf := make([dynamic]u8, 0, 64, h.allocator)
	defer delete(buf)
	if is_debug {
		append(&buf, "[\"DEBUG:\",")
		_ = query.write_json(h, &buf, v, {double = jq_double, too_deep = TOO_DEEP_TEXT})
		append(&buf, "]\n")
	} else if query.type_of(v) == .String {
		append(&buf, query.text_of(v))
	} else {
		_ = query.write_json(h, &buf, v, {double = jq_double, too_deep = TOO_DEEP_TEXT})
	}
	sync.mutex_guard(&sh.stderr_lock)
	_, _ = io.write(sh.stderr_w, buf[:])
}

new_jq_worker :: proc(sh: ^Shared_Jq_State, alloc: runtime.Allocator, exclusive: bool) -> (^Jq_Worker, bool) {
	w := new(Jq_Worker, alloc)
	w^ = {
		shared       = sh,
		scratch      = make([dynamic]u8, 0, 256, alloc),
		where_sb     = strings.builder_make(alloc),
		is_exclusive = exclusive,
		alloc        = alloc,
	}
	query.heap_init(&w.h, alloc, memory_limit = sh.budget.memory, depth = int(sh.budget.depth))
	w.h.keep_origins = sh.where_mode
	globs, gok := build_globals_from_shared(&w.h, sh.main_prog, sh, alloc)
	if !gok {
		strings.builder_destroy(&w.where_sb)
		delete(w.scratch)
		query.heap_destroy(&w.h)
		free(w, alloc)
		return nil, false
	}
	w.globals = globs
	w.hook_ctx = {
		o        = sh.o,
		stderr_w = sh.stderr_w,
		alloc    = alloc,
	}
	w.hooks = {
		data       = w,
		markup     = markup_opts_for_jq,
		parse_json = parse_json_for_jq,
		now        = proc(_: rawptr) -> f64 {return f64(time.time_to_unix_nano(time.now())) / 1e9},
		random     = proc(_: rawptr, b: []u8) {runtime.rand_bytes(b)},
		debug      = proc(d: rawptr, v: query.Value, h: ^query.Heap) {hook_msg((^Jq_Worker)(d).shared, v, h, true)},
		stderr     = proc(d: rawptr, v: query.Value, h: ^query.Heap) {hook_msg((^Jq_Worker)(d).shared, v, h, false)},
		input      = proc(d: rawptr, h: ^query.Heap) -> (query.Value, bool, query.Status) {return hook_next_input(&(^Jq_Worker)(d).hook_ctx, h)},
		input_filename = proc(d: rawptr, h: ^query.Heap) -> (query.Value, query.Status) {
			fp := (^Jq_Worker)(d).hook_ctx.file_path
			return query.text_value(h, fp)
		},
		input_line_number = proc(d: rawptr) -> i64 {return (^Jq_Worker)(d).hook_ctx.line_number},
		zone = proc(d: rawptr, secs: i64) -> (query.Zone, bool) {
			return local_zone_at(&(^Jq_Worker)(d).shared.zones, secs)
		},
	}
	jq.run_init(&w.run, sh.main_prog, &w.h, globs, &w.hooks, steps = int(sh.budget.steps))
	if sh.each_prog != nil {
		jq.run_init(&w.each_run, sh.each_prog, &w.h, globs, &w.hooks, steps = int(sh.budget.steps))
		w.has_each_run = true
	}
	if sh.pred_prog != nil {
		jq.run_init(&w.pred_run, sh.pred_prog, &w.h, globs, &w.hooks, steps = int(sh.budget.steps))
		w.has_pred_run = true
	}
	return w, true
}

free_jq_worker :: proc(w: ^Jq_Worker) {
	if w == nil {
		return
	}
	a := w.alloc
	hook_ctx_close(&w.hook_ctx)
	if w.has_each_run {
		jq.run_destroy(&w.each_run)
	}
	if w.has_pred_run {
		jq.run_destroy(&w.pred_run)
	}
	jq.run_destroy(&w.run)
	for g in w.globals {
		query.release(&w.h, g)
	}
	delete(w.globals, a)
	delete(w.scratch)
	strings.builder_destroy(&w.where_sb)
	if w.err_msg != "" {
		delete(w.err_msg, a)
	}
	if w.halt_msg != "" {
		delete(w.halt_msg, a)
	}
	if w.tw != nil {
		tw_alloc := w.tw.allocator if w.tw.allocator.procedure != nil else a
		write.table_writer_drop(w.tw)
		free(w.tw, tw_alloc)
		w.tw = nil
	}
	if w.rtw != nil {
		rtw_alloc := w.rtw.allocator if w.rtw.allocator.procedure != nil else a
		render_table_writer_drop(w.rtw)
		free(w.rtw, rtw_alloc)
		w.rtw = nil
	}
	query.heap_destroy(&w.h)
	free(w, a)
}

@(private = "file")
acquire_worker :: proc(sh: ^Shared_Jq_State) -> (^Jq_Worker, bool) {
	sync.mutex_lock(&sh.pool_lock)
	if len(sh.free_workers) > 0 {
		w := pop(&sh.free_workers)
		sync.mutex_unlock(&sh.pool_lock)
		return w, true
	}
	sync.mutex_unlock(&sh.pool_lock)
	return new_jq_worker(sh, sh.locked_alloc, true)
}

@(private = "file")
release_worker :: proc(sh: ^Shared_Jq_State, w: ^Jq_Worker) {
	if w == nil {
		return
	}
	if w.err_msg != "" {
		delete(w.err_msg, w.alloc)
		w.err_msg = ""
	}
	if w.halt_msg != "" {
		delete(w.halt_msg, w.alloc)
		w.halt_msg = ""
	}
	w.has_halt = false
	w.halt_code = 0
	w.out_count = 0
	w.last_falsy = false
	w.nul_err = false
	w.file_name = ""
	w.hook_ctx.file_path = ""
	w.tw = nil
	w.rtw = nil
	sync.mutex_guard(&sh.pool_lock)
	append(&sh.free_workers, w)
}

@(private = "file")
worker_hook_init :: proc(pctx: rawptr, _: int, _: runtime.Allocator) -> rawptr {
	p := (^Jq_Worker)(pctx)
	if p == nil || p.shared == nil {
		return nil
	}
	c, ok := acquire_worker(p.shared)
	if !ok {
		return nil
	}
	c.file_name = p.file_name
	return c
}

@(private = "file")
worker_hook_fini :: proc(_: rawptr, _: int, wctx: rawptr) {
	w := (^Jq_Worker)(wctx)
	if w == nil {
		return
	}
	release_worker(w.shared, w)
}

@(private = "file")
merge_worker_outcome :: proc(sh: ^Shared_Jq_State, w: ^Jq_Worker, key: Order_Key, ee: engine.Exec_Error, count_e := true) {
	if ee == .Tainted {
		return
	}
	sync.mutex_guard(&sh.merge_lock)
	m := &sh.merge
	if count_e && w.out_count > 0 {
		m.total_emitted += w.out_count
		if !m.has_last || key_ge(key, m.last_key) {
			m.has_last = true
			m.last_key = key
			m.last_falsy = w.last_falsy
		}
	}
	if w.nul_err {
		m.nul_err = true
	}
	if ee != .None && ee != .Stopped {
		if !m.has_err || key_lt(key, m.err_key) {
			m.has_err = true
			m.err_key = key
			m.err_kind = ee
			if m.err_msg != "" {
				delete(m.err_msg, sh.locked_alloc)
				m.err_msg = ""
			}
			if w.err_msg != "" {
				m.err_msg = strings.clone(w.err_msg, sh.locked_alloc)
			}
			if m.halt_msg != "" {
				delete(m.halt_msg, sh.locked_alloc)
				m.halt_msg = ""
			}
			if w.halt_msg != "" {
				m.halt_msg = strings.clone(w.halt_msg, sh.locked_alloc)
			}
			if w.has_halt {
				m.halt_code = w.halt_code
			}
		}
	}
}

@(private = "file")
build_where_prefix :: proc(sb: ^strings.Builder, h: ^query.Heap, v: query.Value, file, norm_path: string) -> []u8 {
	strings.builder_reset(sb)
	if pl, pok := query.value_place(h, v); pok {
		where_prefix(sb, file, pl)
	}
	if norm_path != "" {
		fmt.sbprintf(sb, "%s ", norm_path)
	}
	return transmute([]u8)strings.to_string(sb^)
}

format_halt_message :: proc(w: ^Jq_Worker, hs: jq.Halt_State) {
	if hs.value.kind == .Absent || hs.value.kind == .Null {
		return
	}
	buf := make([dynamic]u8, 0, 64, w.alloc)
	defer delete(buf)
	if query.type_of(hs.value) == .String {
		append(&buf, query.text_of(hs.value))
	} else {
		_ = query.write_json(&w.h, &buf, hs.value, {double = jq_double, too_deep = TOO_DEEP_TEXT})
	}
	append(&buf, '\n')
	if w.halt_msg != "" {
		delete(w.halt_msg, w.alloc)
	}
	w.halt_msg = strings.clone(string(buf[:]), w.alloc)
}

@(private = "file")
emit_rendered_jq_value :: proc(
	w: ^Jq_Worker,
	v: query.Value,
	meta: engine.Record_Meta,
	emit: engine.Emitter,
	cfg: ^Render_Config,
	allow_tabular := true,
) -> engine.Exec_Error {
	sh := w.shared
	if allow_tabular && cfg.to_tabular {
		if w.tw == nil {
			if sh != nil && w == sh.serial_worker && w.alloc.procedure != nil {
				no_hdr := sh.direct_tab_active && sh.osink.total_written > sh.direct_tab_bytes
				if !ensure_jq_tab_writer(sh.o, cfg, w, sh.osink, w.alloc, force_no_header = no_hdr) {
					w.err_msg = strings.clone("cannot start tabular writer", w.alloc)
					return .Write_Error
				}
			} else {
				w.err_msg = strings.clone("tabular output requires serial execution", w.alloc)
				return .Write_Error
			}
		}
		if !write_table_row(&w.h, v, w.tw) {
			err := w.tw.err if w.tw.err != nil else write.Error(write.Refused{why = .Not_A_Table})
			if ioe, is_io := err.(io.Error); is_io {
				sh.osink.failed = true
				sh.osink.io_err = ioe
				return .Stopped
			}
			w.err_msg = write_error_string(err, w.alloc)
			return .Write_Error
		}
		return .None
	}
	if allow_tabular && cfg.to_render != .None {
		if w.rtw == nil {
			if sh != nil && w == sh.serial_worker && w.alloc.procedure != nil {
				if !ensure_jq_render_writer(sh.o, cfg, w, sh.osink, w.alloc) {
					w.err_msg = strings.clone("cannot start table renderer", w.alloc)
					return .Write_Error
				}
			} else {
				w.err_msg = strings.clone("table/markdown output requires serial execution", w.alloc)
				return .Write_Error
			}
		}
		if !render_table_writer_value(w.rtw, &w.h, v) {
			if w.h.tainted {
				return .Tainted
			}
			err := w.rtw.err if w.rtw.err != nil else write.Error(write.Refused{why = .No_Spelling})
			if ioe, is_io := err.(io.Error); is_io {
				sh.osink.failed = true
				sh.osink.io_err = ioe
				return .Stopped
			}
			w.err_msg = write_error_string(err, w.alloc)
			return .Write_Error
		}
		return .None
	}
	if allow_tabular && cfg.to_non_json {
		if cfg.one_doc && sync.atomic_load(&cfg.docs_emitted) >= 1 {
			w.err_msg = fmt.aprintf("--to %s writes one document: the filter gave a second output; collect the outputs into one value with [...]", cfg.to_name, allocator = w.alloc)
			return .Write_Error
		}
		clear(&w.scratch)
		ew: Emit_Writer
		emit_writer_init(&ew, emit)
		ok, emsg := write_value_as_format(&w.h, v, cfg.to_spec, cfg.write_opts, &w.scratch, emit_writer_io(&ew), int(sh.budget.depth), w.alloc)
		if !ok {
			if w.h.tainted {
				return .Tainted
			}
			if ew.stopped {
				return .Stopped
			}
			w.err_msg = emsg
			return .Write_Error
		}
		e, _ := engine.entry_of_spec(cfg.to_spec)
		if !e.binary && (!ew.wrote_any || ew.last_byte != '\n') {
			nl := [1]u8{'\n'}
			if _, werr := io.write(emit_writer_io(&ew), nl[:]); werr != .None {
				return .Stopped
			}
		}
		if !emit_writer_flush(&ew) {
			return .Stopped
		}
		if cfg.one_doc {
			_ = sync.atomic_add(&cfg.docs_emitted, 1)
		}
		return .None
	}
	prefix: []u8
	if sh.where_mode && allow_tabular {
		fn := meta.file_path if meta.file_path != "" else w.file_name
		prefix = build_where_prefix(&w.where_sb, &w.h, v, fn, "")
	}
	stream_chunks := (emit.fn == out_sink_emit)
	st, stopped := render_value_to_emitter(&w.h, v, cfg, prefix, &w.scratch, emit, stream_chunks, &w.nul_err)
	if stopped {
		return .Stopped
	}
	if st != .Ok {
		if w.h.tainted {
			return .Tainted
		}
		if w.nul_err {
			w.err_msg = strings.clone("Cannot dump a string containing NUL with --raw-output0 option", w.alloc)
			return .Failed
		}
		e := query.take_error(&w.h)
		w.err_msg = jq.error_message(&w.h, &e, w.alloc)
		query.destroy_error(&w.h, &e)
		return .Failed
	}
	return .None
}

@(private = "file")
run_prog_on_value :: proc(
	w: ^Jq_Worker,
	run_ptr: ^jq.Run,
	inp: query.Value,
	meta: engine.Record_Meta,
	emit: engine.Emitter,
	cfg: ^Render_Config,
	allow_tabular: bool,
) -> engine.Exec_Error {
	Bridge :: struct {
		w:             ^Jq_Worker,
		meta:          engine.Record_Meta,
		emit:          engine.Emitter,
		cfg:           ^Render_Config,
		allow_tabular: bool,
		err:           engine.Exec_Error,
	}
	w.out_count = 0
	w.last_falsy = false
	w.has_halt = false
	w.nul_err = false
	if w.err_msg != "" {
		delete(w.err_msg, w.alloc)
		w.err_msg = ""
	}
	if w.halt_msg != "" {
		delete(w.halt_msg, w.alloc)
		w.halt_msg = ""
	}
	br := Bridge{w = w, meta = meta, emit = emit, cfg = cfg, allow_tabular = allow_tabular}
	end := jq.run_value(run_ptr, inp, proc(d: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		b := (^Bridge)(d)
		defer query.release(h, v)
		vt := query.type_of(v)
		b.w.out_count += 1
		b.w.last_falsy = (vt == .Null || vt == .False || vt == .Absent)
		if err := emit_rendered_jq_value(b.w, v, b.meta, b.emit, b.cfg, b.allow_tabular); err != .None {
			b.err = err
			return false
		}
		return true
	}, &br)
	if br.err != .None {
		return br.err
	}
	if w.h.tainted || end == .Tainted {
		return .Tainted
	}
	switch end {
	case .Done:
		return .None
	case .Stopped:
		return .Stopped
	case .Tainted:
		return .Tainted
	case .Halted:
		hs := jq.run_halt(run_ptr)
		w.has_halt = true
		w.halt_code = hs.code
		format_halt_message(w, hs)
		return .Halted
	case .Failed:
		e := query.take_error(&w.h)
		w.err_msg = jq.error_message(&w.h, &e, w.alloc)
		query.destroy_error(&w.h, &e)
		return .Failed
	}
	return .None
}

@(private = "file")
eval_jq_with :: proc(
	w: ^Jq_Worker,
	use_each: bool,
	doc: ^tape.Document,
	meta: engine.Record_Meta,
	emit: engine.Emitter,
) -> engine.Exec_Error {
	sh := w.shared
	cur_w := w
	acquired := false
	if !w.is_exclusive {
		cw, ok := acquire_worker(sh)
		if !ok {
			return .No_Memory
		}
		cw.file_name = meta.file_path if meta.file_path != "" else w.file_name
		cur_w = cw
		acquired = true
	}
	defer if acquired {
		release_worker(sh, cur_w)
	}

	cur_w.hook_ctx.file_path = meta.file_path if meta.file_path != "" else cur_w.file_name
	cur_w.hook_ctx.line_number = i64(meta.record_index) + 1
	cur_w.h.keep_origins = sh.where_mode
	cur_w.h.tainted = false
	query.clear_error(&cur_w.h)

	run_ptr := &cur_w.each_run if (use_each && cur_w.has_each_run) else &cur_w.run
	cfg := &sh.compact_cfg if (use_each && sh.collect_each) else sh.cfg
	allow_tab := !(use_each && sh.collect_each)
	count_e := !(use_each && sh.collect_each)

	if len(doc.nodes) > 0 && sh.o.xml_arrays == .Schema && sh.xml_schema_desc != nil && doc.format != nil && doc.format.options == .Xml {
		if nerr := engine.apply_xml_arrays(doc, .Schema, sh.xml_schema_desc, cur_w.alloc); nerr != nil {
			cur_w.err_msg = strings.clone("XML array normalization failed", cur_w.alloc)
			merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, .Failed, count_e)
			return .Failed
		}
	}

	ee: engine.Exec_Error
	was_unwritten := sh.direct_tab_active && cur_w == sh.serial_worker && sh.osink.total_written == sh.direct_tab_bytes
	if len(doc.nodes) == 0 {
		ee = run_prog_on_value(cur_w, run_ptr, query.NULL, meta, emit, cfg, allow_tab)
	} else if !use_each && sh.needs_overlay && doc.partial == nil {
		inp, _, ost := query.overlay_from_doc(&cur_w.h, doc^, doc_owned = false)
		if ost != .Ok {
			return .Failed
		}
		_ = query.retain(inp)
		ee = run_prog_on_value(cur_w, run_ptr, inp, meta, emit, cfg, allow_tab)
		query.release(&cur_w.h, inp)
		cur_w.h.write_fact, cur_w.h.write_fact_data = nil, nil
	} else {
		inp, st := query.document_value(&cur_w.h, doc^, owned = false)
		if st != .Ok {
			return .Failed
		}
		ee = run_prog_on_value(cur_w, run_ptr, inp, meta, emit, cfg, allow_tab)
	}
	if sh.direct_tab_active && cur_w == sh.serial_worker && cur_w.tw != nil {
		tcode := finish_tab_writer(cur_w.tw, sh.osink, sh.stderr_w, cur_w.alloc)
		cur_w.tw = nil
		if tcode != EXIT_OK && (ee == .None || ee == .Stopped) {
			ee = .Stopped if sh.osink.failed else .Write_Error
		} else if was_unwritten && sh.osink.total_written > sh.direct_tab_bytes && !sh.o.dsv_out.no_header {
			sh.direct_tab.suppress_next_hdr = true
		}
	}
	if !((ee == .None || ee == .Stopped) && !sh.o.exit_status && !cur_w.nul_err) {
		merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, ee, count_e)
	}
	return ee
}

@(private = "file")
eval_jq_doc :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	w := (^Jq_Worker)(ctx)
	if w == nil {
		return .No_Memory
	}
	return eval_jq_with(w, false, doc, meta, emit)
}

@(private = "file")
eval_jq_each :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	w := (^Jq_Worker)(ctx)
	if w == nil {
		return .No_Memory
	}
	return eval_jq_with(w, true, doc, meta, emit)
}

@(private = "file")
eval_jq_each_count :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (count: u64, err: engine.Exec_Error) {
	w := (^Jq_Worker)(ctx)
	if w == nil {
		return 0, .No_Memory
	}
	sh := w.shared
	cur_w := w
	acquired := false
	if !w.is_exclusive {
		cw, ok := acquire_worker(sh)
		if !ok {
			return 0, .No_Memory
		}
		cw.file_name = meta.file_path if meta.file_path != "" else w.file_name
		cur_w = cw
		acquired = true
	}
	defer if acquired {
		release_worker(sh, cur_w)
	}

	cur_w.hook_ctx.file_path = meta.file_path if meta.file_path != "" else cur_w.file_name
	cur_w.hook_ctx.line_number = i64(meta.record_index) + 1
	cur_w.h.keep_origins = sh.where_mode
	cur_w.h.tainted = false
	query.clear_error(&cur_w.h)
	cur_w.out_count = 0
	cur_w.last_falsy = false
	cur_w.has_halt = false
	cur_w.nul_err = false
	if cur_w.err_msg != "" {
		delete(cur_w.err_msg, cur_w.alloc)
		cur_w.err_msg = ""
	}
	if cur_w.halt_msg != "" {
		delete(cur_w.halt_msg, cur_w.alloc)
		cur_w.halt_msg = ""
	}

	if len(doc.nodes) > 0 && sh.o.xml_arrays == .Schema && sh.xml_schema_desc != nil && doc.format != nil && doc.format.options == .Xml {
		if nerr := engine.apply_xml_arrays(doc, .Schema, sh.xml_schema_desc, cur_w.alloc); nerr != nil {
			cur_w.err_msg = strings.clone("XML array normalization failed", cur_w.alloc)
			merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, .Failed, false)
			return 0, .Failed
		}
	}

	run_ptr := &cur_w.each_run if cur_w.has_each_run else &cur_w.run
	inp: query.Value
	if len(doc.nodes) == 0 {
		inp = query.NULL
	} else {
		st: query.Status
		inp, st = query.document_value(&cur_w.h, doc^, owned = false)
		if st != .Ok {
			return 0, .Failed
		}
	}

	cnt, end := jq.run_count(run_ptr, inp)
	ee := engine.Exec_Error.None
	if cur_w.h.tainted || end == .Tainted {
		return 0, .Tainted
	}
	switch end {
	case .Done:
	case .Stopped:
		ee = .Stopped
	case .Tainted:
		return 0, .Tainted
	case .Halted:
		hs := jq.run_halt(run_ptr)
		cur_w.has_halt = true
		cur_w.halt_code = hs.code
		format_halt_message(cur_w, hs)
		ee = .Halted
	case .Failed:
		e := query.take_error(&cur_w.h)
		cur_w.err_msg = jq.error_message(&cur_w.h, &e, cur_w.alloc)
		query.destroy_error(&cur_w.h, &e)
		ee = .Failed
	}
	if ee != .None {
		merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, ee, false)
		return 0, ee
	}
	return cnt, .None
}

@(private = "file")
emit_jq_spine_length :: proc(ctx: rawptr, total: u64, emit: engine.Emitter) -> engine.Exec_Error {
	pw := (^Jq_Worker)(ctx)
	if pw == nil || pw.shared == nil {
		return .No_Memory
	}
	sh := pw.shared
	cur_w := pw
	acquired := false
	if !pw.is_exclusive {
		cw, ok := acquire_worker(sh)
		if !ok {
			return .No_Memory
		}
		cw.file_name = pw.file_name
		cur_w = cw
		acquired = true
	}
	defer if acquired {
		release_worker(sh, cur_w)
	}
	cur_w.hook_ctx.file_path = pw.file_name
	cur_w.h.keep_origins = sh.where_mode
	cur_w.h.tainted = false
	query.clear_error(&cur_w.h)
	cur_w.out_count = 1
	cur_w.last_falsy = false
	cur_w.nul_err = false

	val := query.int_value(i64(total)) if total <= u64(max(i64)) else query.double_value(f64(total))
	ee := emit_rendered_jq_value(cur_w, val, {file_path = pw.file_name}, emit, sh.cfg, true)
	if !((ee == .None || ee == .Stopped) && !sh.o.exit_status && !cur_w.nul_err) {
		merge_worker_outcome(sh, cur_w, {file_idx = max(int), rec_idx = max(u64)}, ee, true)
	} else if sh.o.exit_status {
		merge_worker_outcome(sh, cur_w, {file_idx = max(int), rec_idx = max(u64)}, ee, true)
	}
	return ee
}

@(private = "file")
eval_jq_pred :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (matched: bool, err: engine.Exec_Error) {
	sh := (^Shared_Jq_State)(ctx)
	if sh == nil || sh.pred_prog == nil {
		return false, .Unsupported
	}
	w, ok := acquire_worker(sh)
	if !ok {
		return false, .No_Memory
	}
	defer release_worker(sh, w)

	w.hook_ctx.file_path = meta.file_path
	w.hook_ctx.line_number = i64(meta.record_index) + 1
	w.h.keep_origins = false
	w.h.tainted = false
	query.clear_error(&w.h)
	w.out_count = 0
	w.has_halt = false
	if w.err_msg != "" {
		delete(w.err_msg, w.alloc)
		w.err_msg = ""
	}
	if w.halt_msg != "" {
		delete(w.halt_msg, w.alloc)
		w.halt_msg = ""
	}

	if len(doc.nodes) > 0 && sh.o.xml_arrays == .Schema && sh.xml_schema_desc != nil && doc.format != nil && doc.format.options == .Xml {
		if nerr := engine.apply_xml_arrays(doc, .Schema, sh.xml_schema_desc, w.alloc); nerr != nil {
			w.err_msg = strings.clone("XML array normalization failed", w.alloc)
			merge_worker_outcome(sh, w, {file_idx = meta.file_index, rec_idx = meta.record_index}, .Failed, false)
			return false, .Failed
		}
	}

	inp, st := query.document_value(&w.h, doc^, owned = false)
	if st != .Ok {
		return false, .Failed
	}

	Pred_State :: struct {
		matched: bool,
	}
	ps := Pred_State{}
	end := jq.run_value(&w.pred_run, inp, proc(d: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		p := (^Pred_State)(d)
		defer query.release(h, v)
		vt := query.type_of(v)
		if vt != .Null && vt != .False && vt != .Absent {
			p.matched = true
		}
		return !p.matched
	}, &ps)

	if w.h.tainted || end == .Tainted {
		return false, .Tainted
	}
	switch end {
	case .Done, .Stopped:
		return ps.matched, .None
	case .Halted:
		hs := jq.run_halt(&w.pred_run)
		w.has_halt = true
		w.halt_code = hs.code
		format_halt_message(w, hs)
		merge_worker_outcome(sh, w, {file_idx = meta.file_index, rec_idx = meta.record_index}, .Halted, false)
		return false, .Halted
	case .Failed:
		e := query.take_error(&w.h)
		w.err_msg = jq.error_message(&w.h, &e, w.alloc)
		query.destroy_error(&w.h, &e)
		merge_worker_outcome(sh, w, {file_idx = meta.file_index, rec_idx = meta.record_index}, .Failed, false)
		return false, .Failed
	case .Tainted:
		return false, .Tainted
	}
	return ps.matched, .None
}

// Tail combiner for Hint 1 `.Collect` (`[.prefix[] | each] | tail`).
@(private = "file")
eval_spine_collect :: proc(ctx: rawptr, _: ^tape.Document, item_outputs: [][]u8, emit: engine.Emitter) -> engine.Exec_Error {
	pw := (^Jq_Worker)(ctx)
	if pw == nil || pw.shared == nil || pw.shared.tail_prog == nil {
		return .Failed
	}
	sh := pw.shared
	ab := strings.builder_make(sh.locked_alloc)
	defer strings.builder_destroy(&ab)
	strings.write_byte(&ab, '[')
	for item, idx in item_outputs {
		if idx > 0 {
			strings.write_byte(&ab, ',')
		}
		strings.write_bytes(&ab, item)
	}
	strings.write_byte(&ab, ']')

	adoc, berr := engine.build(transmute([]u8)strings.to_string(ab), engine.spec_of_id(.Json), {budget = sh.budget}, sh.locked_alloc)
	if berr != nil {
		return .Read_Error
	}
	defer tape.destroy_document(&adoc)

	w, ok := acquire_worker(sh)
	if !ok {
		return .No_Memory
	}
	defer {
		w.tw = nil
		w.rtw = nil
		release_worker(sh, w)
	}

	w.file_name = pw.file_name
	w.hook_ctx.file_path = pw.file_name
	w.h.keep_origins = sh.where_mode
	w.h.tainted = false
	query.clear_error(&w.h)
	w.tw = pw.tw
	w.rtw = pw.rtw

	tail_run: jq.Run
	jq.run_init(&tail_run, sh.tail_prog, &w.h, w.globals, &w.hooks, steps = int(sh.budget.steps))
	defer jq.run_destroy(&tail_run)

	inp, st := query.document_value(&w.h, adoc, owned = false)
	if st != .Ok {
		return .Failed
	}
	ee := run_prog_on_value(w, &tail_run, inp, {file_path = pw.file_name}, emit, sh.cfg, true)
	merge_worker_outcome(sh, w, {file_idx = max(int), rec_idx = max(u64)}, ee, true)
	return ee
}

@(private = "file")
hook_ctx_clear_stream :: proc(hc: ^Hook_Ctx) {
	if hc.stream_heap != nil {
		for i := hc.stream_idx; i < len(hc.stream_events); i += 1 {
			query.release(hc.stream_heap, hc.stream_events[i])
		}
	}
	clear(&hc.stream_events)
	hc.stream_idx = 0
}

@(private = "file")
hook_ctx_close_file :: proc(hc: ^Hook_Ctx) {
	if hc.recs_open {
		rec_loop_close(&hc.rec_loop)
		hc.recs_open = false
	}
	if hc.stream_open {
		byte_stream_close(&hc.raw_stream)
		hc.stream_open = false
	}
	if hc.dsv_header != nil {
		delete(hc.dsv_header, hc.alloc)
		hc.dsv_header = nil
	}
	if hc.file_buf_owned && hc.file_buf != nil {
		delete(hc.file_buf, hc.alloc)
	}
	hc.file_buf = nil
	hc.file_buf_owned = false
	hc.single_done = false
}

@(private = "file")
hook_ctx_close :: proc(hc: ^Hook_Ctx) {
	hook_ctx_close_file(hc)
	hook_ctx_clear_stream(hc)
	delete(hc.stream_events)
	hc.stream_events = nil
	hc.stream_heap = nil
}

@(private = "file")
hook_enqueue_stream_err :: proc(hc: ^Hook_Ctx, h: ^query.Heap, err: tape.Error, src: []u8, fmt_ptr: ^tape.Format) -> bool {
	if h == nil {
		return false
	}
	buf: [256]u8
	msg := tape.error_message(buf[:], err, src, fmt_ptr)
	arr, st := query.make_array(h, 2)
	if st != .Ok {
		return false
	}
	s, s1 := query.text_value(h, msg)
	empty, s2 := query.make_array(h, 0)
	if s1 != .Ok || s2 != .Ok {
		query.release(h, s)
		query.release(h, empty)
		query.release(h, arr)
		return false
	}
	_ = query.append_owned(h, &arr, s)
	_ = query.append_owned(h, &arr, empty)
	if hc.stream_events.allocator.procedure == nil {
		hc.stream_events.allocator = hc.alloc
	}
	append(&hc.stream_events, arr)
	hc.stream_heap = h
	return true
}

@(private = "file")
hook_enqueue_stream_doc :: proc(hc: ^Hook_Ctx, h: ^query.Heap, dv: query.Value) -> bool {
	if hc.stream_prog == nil {
		query.release(h, dv)
		return false
	}
	if hc.stream_events.allocator.procedure == nil {
		hc.stream_events.allocator = hc.alloc
	}
	hc.stream_heap = h
	srun: jq.Run
	jq.run_init(&srun, hc.stream_prog, h, nil)
	defer jq.run_destroy(&srun)
	end := jq.run_value(&srun, dv, proc(d: rawptr, v: query.Value, _h: ^query.Heap) -> bool {
		append(&(^Hook_Ctx)(d).stream_events, v)
		return true
	}, hc)
	return end == .Done
}

@(private = "file")
hook_open_next_file :: proc(hc: ^Hook_Ctx) -> bool {
	for hc.file_idx < len(hc.paths) {
		p := hc.paths[hc.file_idx]
		hc.file_idx += 1
		disp := "<stdin>" if p == "-" else p
		sp, fr := detect_file_spec(hc.o, p)
		e, _ := engine.entry_of_spec(sp)
		if hc.raw_lines {
			bs, ok := byte_stream_open(p, hc.stdin_override, hc.stderr_w, hc.alloc)
			if !ok {
				hc.has_open_err = true
				continue
			}
			hc.raw_stream = bs
			hc.stream_open = true
			hc.file_path = disp
			hc.line_number = 0
			hc.cur_spec = sp
			hc.cur_framing = fr
			return true
		}
		buf, owned, ok := read_input_bytes(p, hc.stdin_override, hc.stderr_w, hc.alloc)
		if !ok {
			hc.has_open_err = true
			continue
		}
		hc.file_buf = buf
		hc.file_buf_owned = owned
		hc.file_path = disp
		hc.line_number = 0
		hc.cur_spec = sp
		hc.cur_framing = fr
		hc.cur_tabular = e.tabular
		hc.single_done = false
		if e.id == .Json && fr == .Single {
			fr = .Concatenated
			hc.cur_framing = .Concatenated
		}
		if tf, framed := engine.to_tape_framing(fr); framed {
			ro := read_opts_of(hc.o, sp, hc.runner)
			serr_mode := hc.o.stream && hc.o.stream_errors
			err_w := io.Writer{} if serr_mode else hc.stderr_w
			skip_recs := hc.o.skip_bad || (fr == .Seq && !serr_mode)
			it, iok := rec_loop_open(buf, sp, fr, ro, skip_recs, disp, err_w, hc.alloc)
			if !iok {
				if serr_mode {
					_ = hook_enqueue_stream_err(hc, hc.stream_heap, it.open_err, buf, e.format)
					hook_ctx_close_file(hc)
					return true
				}
				hook_ctx_close_file(hc)
				return false
			}
			_ = tf
			hc.rec_loop = it
			hc.recs_open = true
			if e.tabular && it.recs != nil && it.recs.pos > 0 && !hc.o.dsv_in.no_header {
				hc.dsv_header = slice.clone(buf[:it.recs.pos], hc.alloc)
			}
		}
		return true
	}
	return false
}

@(private = "file")
hook_next_input :: proc(hc: ^Hook_Ctx, h: ^query.Heap) -> (query.Value, bool, query.Status) {
	serr_mode := hc.o.stream && hc.o.stream_errors
	for {
		if hc.stream_idx < len(hc.stream_events) {
			ev := hc.stream_events[hc.stream_idx]
			hc.stream_idx += 1
			if hc.stream_idx >= len(hc.stream_events) {
				clear(&hc.stream_events)
				hc.stream_idx = 0
			}
			return ev, true, .Ok
		}
		if hc.raw_lines {
			if !hc.stream_open {
				if !hook_open_next_file(hc) {
					return query.ABSENT, false, .Ok
				}
			}
			line: string
			has, had_nl, err := byte_stream_next_raw_line(&hc.raw_stream, &line)
			if err != nil {
				hook_ctx_close_file(hc)
				return query.NULL, true, .Error
			}
			if !has {
				hook_ctx_close_file(hc)
				continue
			}
			if had_nl {
				hc.line_number += 1
			}
			v, st := query.text_value(h, line)
			return v, true, st
		}
		if !hc.recs_open && hc.single_done {
			hook_ctx_close_file(hc)
		}
		if hc.file_buf == nil && !hc.recs_open {
			hc.stream_heap = h
			if !hook_open_next_file(hc) {
				return query.ABSENT, false, .Ok
			}
			if hc.stream_idx < len(hc.stream_events) {
				continue
			}
		}
		if hc.recs_open {
			rec, rinfo, rerr, has := rec_loop_next(&hc.rec_loop)
			if !has {
				tail_err := hc.rec_loop.tail_err
				if tail_err != nil && serr_mode {
					re, _ := engine.entry_of_spec(hc.cur_spec)
					_ = hook_enqueue_stream_err(hc, h, tail_err, hc.file_buf, re.format)
				}
				hook_ctx_close_file(hc)
				if tail_err != nil && !serr_mode {
					return query.NULL, true, .Error
				}
				continue
			}
			if rerr != nil {
				if serr_mode {
					re, _ := engine.entry_of_spec(hc.cur_spec)
					_ = hook_enqueue_stream_err(hc, h, rerr, hc.file_buf, re.format)
					continue
				}
				ignoring := hc.o.skip_bad || hc.cur_framing == .Seq
				_ = print_tape_error(hc.stderr_w, hc.file_path, rerr, hc.file_buf, hc.cur_spec, ignoring)
				if ignoring {
					continue
				}
				hook_ctx_close_file(hc)
				return query.NULL, true, .Error
			}
			ro := read_opts_of(hc.o, hc.cur_spec, nil)
			if hc.cur_tabular {
				row_src := make([]u8, len(hc.dsv_header) + len(rec), hc.alloc)
				if len(hc.dsv_header) > 0 {
					copy(row_src, hc.dsv_header)
				}
				copy(row_src[len(hc.dsv_header):], rec)
				dv, berr, mem_ok := build_doc_val(h, row_src, hc.cur_spec, ro, hc.alloc, owns_src = true)
				if berr != nil || !mem_ok {
					delete(row_src, hc.alloc)
					if berr != nil && serr_mode {
						re, _ := engine.entry_of_spec(hc.cur_spec)
						_ = hook_enqueue_stream_err(hc, h, berr, rec, re.format)
						continue
					}
					if berr != nil {
						adj_err := berr
						hdr_len := u64(len(hc.dsv_header))
						use_row_place := true
						if f, is_f := adj_err.(tape.Fault); is_f && f.at != tape.NO_BYTE {
							if f.at >= hdr_len {
								f.at -= hdr_len
								adj_err = f
							} else {
								use_row_place = false
							}
						} else if ex, is_ex := adj_err.(tape.Exceeded); is_ex && ex.at != tape.NO_BYTE {
							if ex.at >= hdr_len {
								ex.at -= hdr_len
								adj_err = ex
							} else {
								use_row_place = false
							}
						}
						if use_row_place {
							_ = print_tape_error(hc.stderr_w, hc.file_path, adj_err, rec, hc.cur_spec, false, hc.file_buf, rinfo.lo)
						} else {
							_ = print_tape_error(hc.stderr_w, hc.file_path, berr, hc.dsv_header, hc.cur_spec, false, hc.file_buf, 0)
						}
					}
					hook_ctx_close_file(hc)
					return query.NULL, true, .Error
				}
				c, cs := query.cursor_open(h, dv)
				if cs != .Ok {
					query.release(h, dv)
					hook_ctx_close_file(hc)
					return query.NULL, true, .Error
				}
				defer query.cursor_close(&c)
				k, elem, more, ns := query.cursor_next(h, &c)
				query.release(h, k)
				query.release(h, dv)
				if ns != .Ok || !more {
					query.release(h, elem)
					hook_ctx_close_file(hc)
					return query.NULL, true, .Error
				}
				hc.line_number += 1
				if hc.o.stream && hc.stream_prog != nil {
					if !hook_enqueue_stream_doc(hc, h, elem) {
						hook_ctx_close_file(hc)
						return query.NULL, true, .Error
					}
					continue
				}
				return elem, true, .Ok
			}
			rec_copy := slice.clone(rec, hc.alloc)
			dv, berr, mem_ok := build_doc_val(h, rec_copy, hc.cur_spec, ro, hc.alloc, owns_src = true, xml_arrays = hc.o.xml_arrays, xml_desc = hc.xml_schema_desc)
			if berr != nil || !mem_ok {
				delete(rec_copy, hc.alloc)
				if berr != nil && serr_mode {
					re, _ := engine.entry_of_spec(hc.cur_spec)
					_ = hook_enqueue_stream_err(hc, h, berr, rec, re.format)
					continue
				}
				if berr != nil {
					_ = print_tape_error(hc.stderr_w, hc.file_path, berr, rec, hc.cur_spec, false, hc.file_buf, rinfo.lo)
				}
				hook_ctx_close_file(hc)
				return query.NULL, true, .Error
			}
			hc.line_number += 1
			if hc.o.stream && hc.stream_prog != nil {
				if !hook_enqueue_stream_doc(hc, h, dv) {
					hook_ctx_close_file(hc)
					return query.NULL, true, .Error
				}
				continue
			}
			return dv, true, .Ok
		}
		ro := read_opts_of(hc.o, hc.cur_spec, hc.runner)
		src_copy := slice.clone(hc.file_buf, hc.alloc)
		dv, berr, mem_ok := build_doc_val(h, src_copy, hc.cur_spec, ro, hc.alloc, owns_src = true, xml_arrays = hc.o.xml_arrays, xml_desc = hc.xml_schema_desc)
		hc.single_done = true
		if berr != nil || !mem_ok {
			delete(src_copy, hc.alloc)
			if berr != nil && serr_mode {
				re, _ := engine.entry_of_spec(hc.cur_spec)
				_ = hook_enqueue_stream_err(hc, h, berr, hc.file_buf, re.format)
				hook_ctx_close_file(hc)
				continue
			}
			if berr != nil {
				_ = print_tape_error(hc.stderr_w, hc.file_path, berr, hc.file_buf, hc.cur_spec)
			}
			hook_ctx_close_file(hc)
			return query.NULL, true, .Error
		}
		hc.line_number += 1
		if hc.o.stream && hc.stream_prog != nil {
			if !hook_enqueue_stream_doc(hc, h, dv) {
				hook_ctx_close_file(hc)
				return query.NULL, true, .Error
			}
			continue
		}
		return dv, true, .Ok
	}
}

run_query :: proc(
	o: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	runner: ^tape.Runner,
	exe_dir, cwd, home_dir: string,
	alloc: runtime.Allocator,
) -> int {
	to_e, to_ok := engine.entry_of_spec(o.to_spec)
	cfg := Render_Config {
		raw         = o.raw,
		join        = o.join,
		raw0        = o.raw0,
		compact     = o.compact,
		tab         = o.tab,
		indent      = o.indent,
		sort_keys   = o.sort_keys,
		ascii       = o.ascii,
		seq         = o.seq,
		color       = o.color_mode == .Always && !o.raw && !(o.has_to && (o.to_render != .None || to_e.id != .Json)),
		colors      = DEFAULT_COLORS,
		to_spec     = o.to_spec,
		to_framing  = o.to_framing,
		to_name     = o.to_name,
		to_render   = o.to_render,
		to_non_json = o.has_to && o.to_render == .None && !to_e.tabular && !(to_e.id == .Json && o.to_name == "json"),
		to_tabular  = o.has_to && to_ok && to_e.tabular,
		one_doc     = o.has_to && to_ok && (to_e.family == .Toml || to_e.family == .Xml || to_e.family == .Html),
		grow_header = o.grow_header,
		write_opts  = make_write_opts(o, o.to_spec, o.indent),
		dsv_out     = o.dsv_out,
	}
	if spec_env, has_c := os.lookup_env("JQ_COLORS", alloc); has_c {
		defer delete(spec_env, alloc)
		c, co, cok := parse_jq_colors(spec_env, alloc)
		if !cok {
			fmt.wprintln(stderr_w, "Failed to set $JQ_COLORS")
		}
		cfg.colors, cfg.colors_owned = c, co
	}
	defer render_config_destroy(&cfg, alloc)

	if o.jsonpath {
		return run_jsonpath_query(o, &cfg, stdin_override, stdout_w, stderr_w, runner, alloc)
	}
	return run_jq_query(o, &cfg, stdin_override, stdout_w, stderr_w, runner, exe_dir, cwd, home_dir, alloc)
}

compile_jq_cmd :: proc(
	o: ^Options,
	exe_dir, origin_dir, home_dir: string,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> (prog: ^jq.Program, eff_origin: string, ok: bool, code: int) {
	ft, has_f := o.filter.?
	filter_text := ft if has_f else "."
	filter_owned := false
	eff_origin = origin_dir
	if has_f && o.from_file {
		fb, rok := read_path_or_stdin(ft, false, stderr_w, alloc)
		if !rok {
			return nil, origin_dir, false, EXIT_USAGE
		}
		if bytes.index_byte(fb, 0) >= 0 {
			delete(fb, alloc)
			if stderr_w.procedure != nil {
				fmt.wprintln(stderr_w, "stury: error: program file contains NUL bytes")
			}
			return nil, origin_dir, false, EXIT_USAGE
		}
		filter_text, filter_owned = string(fb), true
		if fd := filepath.dir(ft); fd != "" {
			eff_origin = fd
		} else {
			eff_origin = "."
		}
	}
	defer if filter_owned {
		delete(filter_text, alloc)
	}

	var_names := make([dynamic]string, 0, len(o.vars) + len(o.with_sources) + 2, alloc)
	defer delete(var_names)
	append(&var_names, "ARGS", "JQ_BUILD_CONFIGURATION")
	for vs in o.vars {
		if !slice.contains(var_names[:], vs.name) {
			append(&var_names, vs.name)
		}
	}
	for ws in o.with_sources {
		if !slice.contains(var_names[:], ws.name) {
			append(&var_names, ws.name)
		}
	}
	mods := jq.Modules {
		loader     = {read = mod_read_hook, parse_json = parse_json_for_jq},
		search     = o.lib_dirs[:],
		origin     = eff_origin,
		jq_origin  = exe_dir,
		home       = home_dir,
	}
	with_joins := len(o.with_sources) > 0
	p: ^jq.Program
	errs: []jq.Compile_Error
	if with_joins {
		p, errs = jq.compile_with_joins(filter_text, {variables = var_names[:], modules = mods}, alloc)
	} else {
		p, errs = jq.compile(filter_text, {variables = var_names[:], modules = mods}, alloc)
	}
	if len(errs) > 0 {
		jq.destroy_program(p)
		snip_buf: [1024]u8
		for e in errs {
			if e.kind == .Located && len(e.src) > 0 {
				esrc := transmute([]u8)e.src
				off := u64(max(e.loc.start, 0))
				if with_joins && e.file == "" {
					join_len := len(jq.JOIN_STDLIB)
					if len(e.src) == len(filter_text) + join_len {
						if ins := strings.index(e.src, jq.JOIN_STDLIB); ins >= 0 && ins <= len(filter_text) && e.src[:ins] == filter_text[:ins] && e.src[ins + join_len:] == filter_text[ins:] {
							raw_off := max(e.loc.start, 0)
							mapped := raw_off - join_len if raw_off >= ins + join_len else ins if raw_off > ins else raw_off
							esrc = transmute([]u8)filter_text
							off = u64(mapped)
						}
					}
				}
				pl := tape.offset_place(esrc, nil, off)
				fl := e.file if e.file != "" else (ft if (has_f && o.from_file) else "<top-level>")
				if snip, has_snip := tape.error_snippet(snip_buf[:], esrc, off); has_snip {
					fmt.wprintf(stderr_w, "jq: error: %s:%d:%d: %s\n%s", fl, pl.line, pl.col, e.msg, snip)
				} else {
					fmt.wprintf(stderr_w, "jq: error: %s:%d:%d: %s\n", fl, pl.line, pl.col, e.msg)
				}
			} else if e.kind == .Raw {
				fmt.wprintf(stderr_w, "%s\n", e.msg)
			} else {
				m := jq.locate(e, alloc)
				fmt.wprintf(stderr_w, "jq: error: %s\n", m)
				delete(m, alloc)
			}
		}
		fmt.wprintf(stderr_w, "jq: %d compile error%s\n", len(errs), "" if len(errs) == 1 else "s")
		return nil, origin_dir, false, EXIT_COMPILE
	}
	return p, eff_origin, true, EXIT_OK
}

@(private = "file")
explain_decision :: proc(w: io.Writer, plan: ^query.Plan, dec: ^engine.Decision, alloc: runtime.Allocator) {
	eb := strings.builder_make(alloc)
	engine.explain_to(&eb, plan, dec)
	_, _ = io.write_string(w, strings.to_string(eb))
	strings.builder_destroy(&eb)
}

@(private = "file")
fallback_non_direct_route :: proc(
	dec: ^engine.Decision,
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	runner: ^tape.Runner,
	input_bytes: int,
) {
	if dec.framing != .Single {
		rec_par := (dec.framing == .Lines || dec.framing == .Seq) &&
			(dec.entry.family == .Json || dec.entry.family == .Dsv) &&
			runner != nil &&
			runner.threads > 0 &&
			(plan == nil || plan.serial == {}) &&
			!cfg.one_doc &&
			!cfg.to_tabular &&
			cfg.to_render == .None &&
			(input_bytes == 0 || input_bytes >= engine.RECORDS_PARALLEL_FROM)
		dec.kind = .Records_Parallel if rec_par else .Records_Serial
		dec.parallel = rec_par
		return
	}
	dec.kind = .Scan if (dec.entry.supports_scan && !o.where_mode) else .Whole
	dec.parallel = false
}

@(private = "file")
projection_direct_blocked :: proc "contextless" (o: ^Options, cfg: ^Render_Config, total_files: int) -> bool {
	if cfg.to_tabular {
		return !can_direct_tabular(o, cfg, cfg.to_spec) || total_files > 1
	}
	return !o.compact || cfg.color || o.raw || o.join || o.raw0 || o.sort_keys || o.ascii || o.exit_status || cfg.to_non_json || cfg.to_render != .None || o.seq || o.where_mode
}

@(private = "file")
decide_file_route :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sp: engine.Spec,
	fr: engine.Framing,
	input_bytes: int,
	runner: ^tape.Runner,
	file_count: int,
	has_each_cb, has_pred_cb: bool,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
	total_files := 1,
) -> (dec: engine.Decision, eff_fr: engine.Framing) {
	eff_fr = fr
	xml_force_whole := false
	if o.xml_arrays != .Auto {
		if fe, ok := engine.entry_of_spec(sp); ok && fe.family == .Xml {
			xml_force_whole = true
		}
	}
	ropts := engine.Route_Options{
		runner            = runner,
		where_mode        = o.where_mode,
		force_whole       = xml_force_whole,
		dups              = o.dups,
		file_count        = file_count,
		input_bytes       = input_bytes,
		allow_rerun_whole = true,
		serial_eval_ctx   = cfg.one_doc || cfg.to_tabular || cfg.to_render != .None,
	}
	dec = engine.decide(plan, sp, eff_fr, ropts)
	direct_blocked := projection_direct_blocked(o, cfg, total_files)
	if e, ok := engine.entry_of_spec(sp); ok && e.id == .Json && eff_fr == .Single && !o.seq {
		keep_single := (dec.kind == .Spine_Parallel && has_each_cb) ||
			(dec.kind == .Conditional_Whole && (has_pred_cb || (plan != nil && plan.hints.conditional.cmp.op != .None))) ||
			(dec.kind == .Projection_Direct && !direct_blocked) ||
			(dec.kind == .Whole && runner != nil && runner.threads > 0 && input_bytes >= max(engine.RECORDS_PARALLEL_FROM, 4096) && !o.skip_bad)
		if !keep_single {
			eff_fr = .Concatenated
			dec = engine.decide(plan, sp, eff_fr, ropts)
		}
	}
	if dec.kind == .Projection_Direct && direct_blocked {
		fallback_non_direct_route(&dec, o, cfg, plan, runner, input_bytes)
	}
	if dec.kind == .Spine_Parallel && !has_each_cb {
		fallback_non_direct_route(&dec, o, cfg, plan, runner, input_bytes)
	}
	if dec.kind == .Conditional_Whole && plan != nil && plan.hints.conditional.cmp.op == .None && !has_pred_cb {
		fallback_non_direct_route(&dec, o, cfg, plan, runner, input_bytes)
	}
	if o.explain {
		explain_decision(stderr_w, plan, &dec, alloc)
	}
	return dec, eff_fr
}

@(private = "file")
direct_out_of :: proc "contextless" (sp: engine.Spec) -> engine.Direct_Output {
	e, ok := engine.entry_of_spec(sp)
	if !ok {
		return .Json
	}
	if e.id == .Csv {
		return .Csv
	}
	if e.id == .Tsv {
		return .Tsv
	}
	return .Json
}

@(private = "file")
can_direct_tabular :: proc "contextless" (o: ^Options, cfg: ^Render_Config, sp: engine.Spec) -> bool {
	e, ok := engine.entry_of_spec(sp)
	if !ok {
		return false
	}
	return cfg.to_tabular &&
		!o.grow_header &&
		!o.sort_keys &&
		!o.ascii &&
		!o.dsv_out.infer &&
		o.dsv_out.comment == 0 &&
		!o.dsv_out.crlf &&
		o.dsv_out.delimiter == 0 &&
		!o.each &&
		(e.id == .Csv || e.id == .Tsv)
}

@(private = "file")
start_tab_writer :: proc(o: ^Options, cfg: ^Render_Config, sink_w: io.Writer, alloc: runtime.Allocator, force_no_header := false) -> (^write.Table_Writer, bool) {
	if !cfg.to_tabular {
		return nil, true
	}
	e, ok := engine.entry_of_spec(o.to_spec)
	if !ok || !e.tabular {
		return nil, false
	}
	cells := write.Cells.Quoted if e.id == .Csv else .Escaped if e.id == .Tsv else .Bare
	dopts := o.dsv_out
	if force_no_header {
		dopts.no_header = true
	}
	if dopts.delimiter == 0 {
		dopts.delimiter = '\t' if e.id == .Tsv else ','
	}
	wopts := write.Options {
		framing     = .Lines,
		sort_keys   = o.sort_keys,
		grow_header = o.grow_header,
	}
	tw := new(write.Table_Writer, alloc)
	if write.table_writer_start(tw, e.format, cells, dopts, wopts, sink_w, alloc) != nil {
		free(tw, alloc)
		return nil, false
	}
	return tw, true
}

@(private = "file")
finish_tab_writer :: proc(tw: ^write.Table_Writer, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	if tw == nil {
		return EXIT_OK
	}
	tw_alloc := tw.allocator if tw.allocator.procedure != nil else alloc
	_, err := write.table_writer_end(tw)
	free(tw, tw_alloc)
	if err != nil {
		if ioe, is_io := err.(io.Error); is_io {
			osink.failed = true
			osink.io_err = ioe
			return report_stdout_error(stderr_w, ioe)
		}
		msg := write_error_string(err, alloc)
		fmt.wprintf(stderr_w, "stury: error: %s\n", msg)
		delete(msg, alloc)
		return EXIT_RUNTIME
	}
	return EXIT_OK
}

@(private = "file")
direct_nl_emit :: proc(d: rawptr, b: []u8) -> bool {
	return out_stream_bytes_nl((^Out_Stream)(d), b)
}

@(private = "file")
direct_tab_nl_emit :: proc(d: rawptr, b: []u8) -> bool {
	dt := (^Direct_Tab_Sink)(d)
	if dt.suppress_next_hdr {
		dt.suppress_next_hdr = false
		return true
	}
	return out_stream_bytes_nl(dt.osink, b)
}

@(private = "file")
ensure_jq_tab_writer :: proc(o: ^Options, cfg: ^Render_Config, w: ^Jq_Worker, osink: ^Out_Stream, alloc: runtime.Allocator, force_no_header := false) -> bool {
	if !cfg.to_tabular || w.tw != nil {
		return true
	}
	tw, ok := start_tab_writer(o, cfg, out_stream_writer(osink), alloc, force_no_header)
	if !ok {
		return false
	}
	w.tw = tw
	return true
}

@(private = "file")
start_render_writer :: proc(o: ^Options, cfg: ^Render_Config, sink_w: io.Writer, alloc: runtime.Allocator) -> (^Render_Table_Writer, bool) {
	if cfg.to_render == .None {
		return nil, true
	}
	rtw := new(Render_Table_Writer, alloc)
	if !render_table_writer_start(rtw, cfg.to_render, o, sink_w, alloc) {
		free(rtw, alloc)
		return nil, false
	}
	return rtw, true
}

@(private = "file")
finish_render_writer :: proc(rtw: ^Render_Table_Writer, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	if rtw == nil {
		return EXIT_OK
	}
	rtw_alloc := rtw.allocator if rtw.allocator.procedure != nil else alloc
	err := render_table_writer_end(rtw)
	free(rtw, rtw_alloc)
	if err != nil {
		if ioe, is_io := err.(io.Error); is_io {
			osink.failed = true
			osink.io_err = ioe
			return report_stdout_error(stderr_w, ioe)
		}
		msg := write_error_string(err, alloc)
		fmt.wprintf(stderr_w, "stury: error: %s\n", msg)
		delete(msg, alloc)
		return EXIT_RUNTIME
	}
	return EXIT_OK
}

@(private = "file")
ensure_jq_render_writer :: proc(o: ^Options, cfg: ^Render_Config, w: ^Jq_Worker, osink: ^Out_Stream, alloc: runtime.Allocator) -> bool {
	if cfg.to_render == .None || w.rtw != nil {
		return true
	}
	rtw, ok := start_render_writer(o, cfg, out_stream_writer(osink), alloc)
	if !ok {
		return false
	}
	w.rtw = rtw
	return true
}

@(private = "file")
drop_render_writer :: proc(rtw: ^Render_Table_Writer, alloc: runtime.Allocator) {
	if rtw == nil {
		return
	}
	rtw_alloc := rtw.allocator if rtw.allocator.procedure != nil else alloc
	render_table_writer_drop(rtw)
	free(rtw, rtw_alloc)
}

@(private = "file")
finish_jq_writers :: proc(w: ^Jq_Worker, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator, flush_render := true) -> int {
	code := EXIT_OK
	if w.tw != nil {
		tcode := finish_tab_writer(w.tw, osink, stderr_w, alloc)
		w.tw = nil
		if tcode != EXIT_OK {
			code = tcode
		}
	}
	if w.rtw != nil {
		if flush_render {
			rcode := finish_render_writer(w.rtw, osink, stderr_w, alloc)
			w.rtw = nil
			if rcode != EXIT_OK && code == EXIT_OK {
				code = rcode
			}
		} else {
			drop_render_writer(w.rtw, alloc)
			w.rtw = nil
		}
	}
	return code
}

@(private = "file")
finish_jp_writers :: proc(w: ^Jp_Worker, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator, flush_render := true) -> int {
	code := EXIT_OK
	if w.tw != nil {
		tcode := finish_tab_writer(w.tw, osink, stderr_w, alloc)
		w.tw = nil
		if tcode != EXIT_OK {
			code = tcode
		}
	}
	if w.rtw != nil {
		if flush_render {
			rcode := finish_render_writer(w.rtw, osink, stderr_w, alloc)
			w.rtw = nil
			if rcode != EXIT_OK && code == EXIT_OK {
				code = rcode
			}
		} else {
			drop_render_writer(w.rtw, alloc)
			w.rtw = nil
		}
	}
	return code
}

@(private = "file")
exec_jq_on_bytes :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Jq_State,
	worker: ^Jq_Worker,
	osink: ^Out_Stream,
	emit: engine.Emitter,
	qw: ^Quarantine_Writer,
	runner: ^tape.Runner,
	b: []u8,
	disp: string,
	sp: engine.Spec,
	fr: engine.Framing,
	fidx: int,
	total_files: int,
	bad_ctx: ^Quarantine_Bad_Ctx,
	pin: ^Plan_Pin_State,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> (res: engine.Exec_Result, pin_code: int) {
	ro := read_opts_of(o, sp, runner)
	worker.file_name = disp
	worker.hook_ctx = {
		o               = o,
		paths           = nil,
		file_path       = disp,
		xml_schema_desc = sh.xml_schema_desc,
		stderr_w        = stderr_w,
		alloc           = sh.locked_alloc,
	}
	dec, eff_fr := decide_file_route(
		o,
		cfg,
		plan,
		sp,
		fr,
		len(b),
		runner,
		1,
		sh.each_prog != nil,
		sh.pred_prog != nil,
		stderr_w,
		alloc,
		total_files = total_files,
	)
	if dec.kind == .Projection_Direct && cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed {
		fallback_non_direct_route(&dec, o, cfg, plan, runner, len(b))
	}
	can_fallback_concat := eff_fr == .Single && dec.entry.id == .Json
	pin_active := pin != nil && (pin.has_expected || pin.out_path != "")
	pin_applied := false
	if pin_active && !can_fallback_concat {
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
			return {}, pcode
		}
		pin_applied = true
	} else if pin_active && pin.has_expected && !engine.compare_plan_pin(pin.expected, engine.plan_pin_of(&dec)) {
		// Pre-check whether `.Concatenated` fallback could match; if not (or `b` is a valid single doc), fail before emitting.
		cand2 := engine.decide(plan, sp, .Concatenated, {
			runner            = runner,
			where_mode        = o.where_mode,
			dups              = o.dups,
			file_count        = 1,
			input_bytes       = len(b),
			allow_rerun_whole = true,
			serial_eval_ctx   = cfg.one_doc || cfg.to_tabular || cfg.to_render != .None,
		})
		if cand2.kind == .Projection_Direct && (projection_direct_blocked(o, cfg, total_files) || (cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed)) {
			fallback_non_direct_route(&cand2, o, cfg, plan, runner, len(b))
		}
		if !engine.compare_plan_pin(pin.expected, engine.plan_pin_of(&cand2)) || engine.validate(b, sp, ro, alloc) == nil {
			if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
				return {}, pcode
			}
			pin_applied = true
		}
	}
	use_direct := dec.kind == .Projection_Direct
	if use_direct && cfg.to_tabular && worker.tw != nil && total_files == 1 && !worker.tw.stream.headed {
		_ = finish_tab_writer(worker.tw, osink, stderr_w, alloc)
		worker.tw = nil
	}
	if !use_direct && cfg.to_tabular {
		if !ensure_jq_tab_writer(o, cfg, worker, osink, alloc) {
			return {err = .Write_Error}, EXIT_OK
		}
	}
	is_seq := eff_fr == .Seq
	skip_active := o.skip_bad || is_seq
	bad_ctx^ = {
		qw          = qw,
		display     = disp,
		src         = b,
		sp          = sp,
		ignoring    = true,
		skip_active = skip_active,
		stderr_w    = stderr_w,
		alloc       = alloc,
	}
	bad_cb :: proc(ctx: rawptr, bad: tape.Bad_Record) -> bool {
		qc := (^Quarantine_Bad_Ctx)(ctx)
		qc.bad_cnt += 1
		if qc.stderr_w.procedure != nil {
			_ = print_tape_error(qc.stderr_w, qc.display, bad.err, qc.src, qc.sp, qc.ignoring)
		}
		if qc.qw != nil && qc.qw.active {
			_ = quarantine_write_bad(qc.qw, qc.bad_cnt, qc.display, bad.err, bad.text, qc.sp, qc.alloc, qc.src)
		}
		return qc.skip_active
	}
	sh.direct_tab = {osink = osink}
	eff_emit := emit
	if use_direct {
		if cfg.to_tabular {
			sh.direct_tab_bytes = osink.total_written
			sh.direct_tab_active = true
			eff_emit = engine.Emitter{fn = direct_tab_nl_emit, data = &sh.direct_tab}
		} else {
			eff_emit = engine.Emitter{fn = direct_nl_emit, data = osink}
		}
	}
	coalesce_opt := !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.unbuffered && !o.each
	direct_nl_opt := coalesce_opt && !cfg.to_tabular
	sp_hint := &plan.hints.split if plan != nil else nil
	has_count_cb := sh.each_prog != nil && sp_hint != nil && sp_hint.kind == .Length && sp_hint.has_each
	fast_each_opt := sh.fast_json if (sp_hint != nil && (sp_hint.kind == .Stream || (sp_hint.kind == .Collect && !sp_hint.has_tail)) && !sp_hint.has_each) else .None
	collect_compact_opt := sp_hint != nil && sp_hint.kind == .Collect && !sp_hint.has_tail && sh.collect_each && !o.raw && !o.join && !o.raw0 && !o.sort_keys && !o.ascii && o.compact && !cfg.color && !o.seq && !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.where_mode && !o.exit_status
	eopts := engine.Exec_Options{
		eval                   = eval_jq_doc,
		eval_ctx               = worker,
		eval_each              = eval_jq_each if sh.each_prog != nil else nil,
		eval_each_ctx          = worker if sh.each_prog != nil else nil,
		eval_each_count        = eval_jq_each_count if has_count_cb else nil,
		emit_spine_length      = emit_jq_spine_length if has_count_cb else nil,
		pred_eval              = eval_jq_pred if sh.pred_prog != nil else nil,
		pred_ctx               = sh if sh.pred_prog != nil else nil,
		spine_collect          = eval_spine_collect if sh.tail_prog != nil else nil,
		on_bad_record          = bad_cb if skip_active else nil,
		bad_ctx                = bad_ctx,
		workers                = {init = worker_hook_init, fini = worker_hook_fini},
		emit                   = eff_emit,
		read                   = ro,
		runner                 = runner,
		direct_out             = direct_out_of(o.to_spec),
		direct_csv_header      = !o.dsv_out.no_header,
		skip_bad               = skip_active,
		fast_json              = sh.fast_json if sh.ident_main else .None,
		fast_json_each         = fast_each_opt,
		coalesce_emit          = coalesce_opt,
		direct_append_nl       = direct_nl_opt,
		spine_collect_compact  = collect_compact_opt,
		eval_ctx_thread_safe   = true,
		rerun_whole_on_taint   = true,
		file_index             = fidx,
		file_path              = disp,
		allocator              = sh.locked_alloc,
	}
	res = engine.execute(plan, &dec, b, eopts)
	sh.direct_tab_active = false
	sh.direct_tab.suppress_next_hdr = false
	// Rare fallback: single large `.Json` tried `.Single` for `.Spine_Parallel`/direct cleanly falls back to `.Concatenated` ONLY if trailing tokens exist.
	if res.err == .Read_Error && res.emitted == 0 && eff_fr == .Single {
		if fe, ok_e := engine.entry_of_spec(sp); ok_e && fe.id == .Json {
			if f, is_f := res.read_err.(tape.Fault); is_f && f.kind == .Bad_Char {
				dec2 := engine.decide(plan, sp, .Concatenated, {
					runner            = runner,
					where_mode        = o.where_mode,
					dups              = o.dups,
					file_count        = 1,
					input_bytes       = len(b),
					allow_rerun_whole = true,
					serial_eval_ctx   = cfg.one_doc || cfg.to_tabular || cfg.to_render != .None,
				})
				if dec2.kind == .Projection_Direct && (projection_direct_blocked(o, cfg, total_files) || (cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed)) {
					fallback_non_direct_route(&dec2, o, cfg, plan, runner, len(b))
				}
				if pin_active {
					if pcode := plan_pin_apply(pin, &dec2, stderr_w, alloc); pcode != EXIT_OK {
						return {}, pcode
					}
					pin_applied = true
				}
				use_direct2 := dec2.kind == .Projection_Direct
				if !use_direct2 && cfg.to_tabular {
					if !ensure_jq_tab_writer(o, cfg, worker, osink, alloc) {
						return {err = .Write_Error}, EXIT_OK
					}
				}
				eopts2 := eopts
				if use_direct2 {
					if cfg.to_tabular {
						sh.direct_tab_bytes = osink.total_written
						sh.direct_tab_active = true
						eopts2.emit = engine.Emitter{fn = direct_tab_nl_emit, data = &sh.direct_tab}
					} else {
						eopts2.emit = engine.Emitter{fn = direct_nl_emit, data = osink}
					}
				} else {
					eopts2.emit = emit
				}
				res = engine.execute(plan, &dec2, b, eopts2)
				sh.direct_tab_active = false
				sh.direct_tab.suppress_next_hdr = false
			}
		}
	}
	if pin_active && !pin_applied {
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
			return {}, pcode
		}
	}
	return res, EXIT_OK
}

@(private = "file")
stream_stdin_delim :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	worker: ^Jq_Worker,
	osink: ^Out_Stream,
	emit: engine.Emitter,
	qw: ^Quarantine_Writer,
	pin: ^Plan_Pin_State,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> (handled: bool, had_bad: bool, exit_code: int) {
	if o.each || o.null_input || o.raw_input || o.slurp || o.stream {
		return false, false, EXIT_OK
	}
	sp, fr := detect_file_spec(o, "-")
	e, _ := engine.entry_of_spec(sp)
	if e.id != .Json || (fr != .Lines && fr != .Seq) {
		return false, false, EXIT_OK
	}
	if cfg.to_tabular {
		if !ensure_jq_tab_writer(o, cfg, worker, osink, alloc) {
			return true, false, EXIT_RUNTIME
		}
	}
	bs, ok := byte_stream_open("-", nil, stderr_w, alloc)
	if !ok {
		return true, false, EXIT_USAGE
	}
	defer byte_stream_close(&bs)

	if o.explain || o.plan_out != "" || o.plan_file != "" {
		dec := engine.decide(plan, sp, fr, {dups = o.dups, where_mode = o.where_mode})
		// `stream_stdin_delim` always builds each delimited record whole and evaluates serially.
		dec.kind = .Records_Serial
		dec.active_hint = .None
		dec.parallel = false
		dec.demand_mode = .Whole
		dec.primary_why = .Records_Framing
		dec.whys += {.Records_Framing}
		dec.whys -= {.Projection_Direct_Hit, .Conditional_Whole_Hit}
		if o.explain {
			explain_decision(stderr_w, plan, &dec, alloc)
		}
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
			return true, false, pcode
		}
	}
	delim := u8(0x1e) if fr == .Seq else '\n'
	span_buf := make([dynamic]u8, 0, 1024, alloc)
	defer delete(span_buf)

	rec_no := i64(0)
	line_base := i64(1)
	bad_cnt := 0
	for {
		span: []u8
		has, had_delim, rerr := byte_stream_next_delim_span(&bs, delim, &span, &span_buf, fr == .Lines)
		if rerr != nil {
			fmt.wprintf(stderr_w, "stury: error: reading stdin: %s\n", os.error_string(rerr))
			return true, bad_cnt > 0, EXIT_USAGE
		}
		if !has {
			break
		}
		rec_no += 1
		if fr == .Lines && len(bytes.trim_space(span)) == 0 {
			line_base += count_newlines(span) + 1
			continue
		}
		if fr == .Seq && !had_delim {
			if len(bytes.trim_space(span)) == 0 {
				line_base += count_newlines(span)
				continue
			}
			f := tape.Fault{at = 0, kind = .Bad_Char}
			_ = print_tape_error(stderr_w, "<stdin>", f, span, sp, ignoring = true)
			if qw != nil && qw.active {
				_ = quarantine_write_bad(qw, rec_no, "<stdin>", f, span, sp, alloc)
			}
			if o.skip_bad {
				bad_cnt += 1
			}
			line_base += count_newlines(span)
			continue
		}
		doc, berr := engine.build(span, sp, {budget = o.budget, dups = o.dups}, alloc)
		if berr != nil {
			_ = print_tape_error(stderr_w, "<stdin>", berr, span, sp, ignoring = (fr == .Seq || o.skip_bad))
			if qw != nil && qw.active {
				_ = quarantine_write_bad(qw, rec_no, "<stdin>", berr, span, sp, alloc)
			}
			if o.skip_bad {
				bad_cnt += 1
				line_base += count_newlines(span) + (1 if fr == .Lines else 0)
				continue
			}
			if fr == .Seq {
				line_base += count_newlines(span)
				continue
			}
			return true, bad_cnt > 0, EXIT_RUNTIME
		}
		if fr == .Seq && len(doc.nodes) > 0 && doc.nodes[0].kind == .Number && len(span) > 0 {
			last_b := span[len(span) - 1]
			if last_b != ' ' && last_b != '\t' && last_b != '\r' && last_b != '\n' {
				tape.destroy_document(&doc)
				f := tape.Fault{at = u64(len(span)), kind = .Bad_Number}
				if stderr_w.procedure != nil {
					snip_buf: [1024]u8
					if snip, has_snip := tape.error_snippet(snip_buf[:], span, u64(len(span))); has_snip {
						fmt.wprintf(stderr_w, "stury: ignoring parse error: <stdin>:%d:%d: Potentially truncated top-level numeric value\n%s", line_base + count_newlines(span), len(span) + 1, snip)
					} else {
						fmt.wprintf(stderr_w, "stury: ignoring parse error: <stdin>:%d:%d: Potentially truncated top-level numeric value\n", line_base + count_newlines(span), len(span) + 1)
					}
				}
				if qw != nil && qw.active {
					_ = quarantine_write_bad(qw, rec_no, "<stdin>", f, span, sp, alloc)
				}
				if o.skip_bad {
					bad_cnt += 1
				}
				line_base += count_newlines(span)
				continue
			}
		}
		worker.file_name = "<stdin>"
		worker.hook_ctx.file_path = "<stdin>"
		worker.hook_ctx.line_number = line_base
		ee := eval_jq_doc(worker, &doc, {file_index = 0, file_path = "<stdin>", record_index = u64(rec_no - 1), raw_bytes = span}, emit)
		tape.destroy_document(&doc)
		if ee == .Halted {
			return true, bad_cnt > 0, worker.halt_code
		}
		if osink.failed {
			return true, bad_cnt > 0, report_out_stream_error(osink, stderr_w)
		}
		if ee == .Stopped {
			return true, bad_cnt > 0, EXIT_OK
		}
		if ee != .None {
			return true, bad_cnt > 0, handle_shared_result(o, worker.shared, worker, {err = ee}, "<stdin>", span, sp, stderr_w, alloc)
		}
		line_base += count_newlines(span) + (1 if fr == .Lines else 0)
	}
	return true, bad_cnt > 0, EXIT_OK
}

@(private = "file")
total_regular_bytes_small :: proc(o: ^Options, paths: []string, alloc: runtime.Allocator) -> (ok: bool) {
	total := i64(0)
	for p in paths {
		if p == "-" {
			return false
		}
		fi, err := os.stat(p, alloc)
		if err != nil {
			return false
		}
		is_reg := fi.type == .Regular
		sz := fi.size
		os.file_info_delete(fi, alloc)
		if !is_reg {
			return false
		}
		total += sz
		if total > MAX_FILES_PARALLEL_BYTES {
			return false
		}
	}
	return true
}

@(private = "file")
find_files_read_error :: proc(
	o: ^Options,
	plan: ^query.Plan,
	finputs: []engine.File_Input,
	ro: tape.Options,
	alloc: runtime.Allocator,
) -> (idx: int, rerr: tape.Error) {
	nop_eval :: proc(_: rawptr, _: ^tape.Document, _: engine.Record_Meta, _: engine.Emitter) -> engine.Exec_Error {
		return .None
	}
	for fi, k in finputs {
		f_dec := engine.decide(plan, fi.spec, fi.framing, {where_mode = o.where_mode, dups = o.dups, file_count = 1, input_bytes = len(fi.src)})
		sub := engine.execute(plan, &f_dec, fi.src, {
			eval                 = nop_eval,
			read                 = ro,
			direct_out           = direct_out_of(o.to_spec),
			direct_csv_header    = !o.dsv_out.no_header,
			rerun_whole_on_taint = false,
			allocator            = alloc,
		})
		if sub.err == .Read_Error {
			return k, sub.read_err
		}
	}
	for fi, k in finputs {
		if _, framed := engine.to_tape_framing(fi.framing); framed {
			it, ok := rec_loop_open(fi.src, fi.spec, fi.framing, ro, false, fi.path, io.Writer{}, alloc)
			if !ok {
				return k, it.open_err
			}
			for rec, _, err in rec_loop_next(&it) {
				if err != nil {
					rec_loop_close(&it)
					return k, err
				}
				doc, berr := engine.build(rec, fi.spec, ro, alloc)
				if berr != nil {
					rec_loop_close(&it)
					return k, berr
				}
				tape.destroy_document(&doc)
			}
			tail_err := it.tail_err
			rec_loop_close(&it)
			if tail_err != nil {
				return k, tail_err
			}
		} else {
			doc, berr := engine.build(fi.src, fi.spec, ro, alloc)
			if berr != nil {
				return k, berr
			}
			tape.destroy_document(&doc)
		}
	}
	return 0, nil
}

@(private = "file")
run_jq_query :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	base_runner: ^tape.Runner,
	exe_dir, origin_dir, home_dir: string,
	alloc: runtime.Allocator,
) -> int {
	prog, eff_origin, cok, ccode := compile_jq_cmd(o, exe_dir, origin_dir, home_dir, stderr_w, alloc)
	_ = eff_origin
	if !cok {
		return ccode
	}
	defer jq.destroy_program(prog)

	plan: jq.Plan
	if len(o.with_sources) > 0 {
		ext_names := make([]string, len(o.with_sources), alloc)
		for ws, i in o.with_sources {
			ext_names[i] = ws.name
		}
		plan, _ = jq.analyze_plan_with_vars(prog, ext_names, {null_input = o.null_input, slurp = o.slurp, raw_input = o.raw_input, stream = o.stream, materialize_each = true}, alloc)
		delete(ext_names, alloc)
	} else {
		plan = jq.analyze(prog, {null_input = o.null_input, slurp = o.slurp, raw_input = o.raw_input, stream = o.stream, materialize_each = true}, alloc)
	}
	defer jq.destroy_plan(&plan)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, cfg.color)

	xml_sc: ^schema.Compiled
	if o.xml_arrays == .Schema && o.schema_file != "" {
		sc_ok: bool
		xml_sc, _, sc_ok = compile_schema_file(o, o.schema_file, stderr_w, alloc)
		if !sc_ok {
			return EXIT_USAGE
		}
	}
	defer schema.destroy(xml_sc)

	sh, serr := shared_jq_init(o, cfg, prog, &plan, &osink, stderr_w, alloc)
	if serr != "" {
		fmt.wprintf(stderr_w, "stury: error: %s\n", serr)
		delete(serr, alloc)
		return EXIT_USAGE
	}
	defer shared_jq_destroy(sh)
	if xml_sc != nil {
		sh.xml_schema_desc = xml_sc.description
	}
	if len(o.with_sources) > 0 {
		if acode := load_shared_aux(sh, o, &plan.contract, stderr_w, alloc); acode != EXIT_OK {
			return acode
		}
	}

	worker, wok := new_jq_worker(sh, sh.locked_alloc, true)
	if !wok {
		fmt.wprintln(stderr_w, "stury: error: out of memory")
		return EXIT_RUNTIME
	}
	sh.serial_worker = worker
	defer free_jq_worker(worker)

	pin: Plan_Pin_State
	if !plan_pin_init(&pin, o, stderr_w, alloc) {
		return EXIT_USAGE
	}
	defer plan_pin_destroy(&pin)

	qw: Quarantine_Writer
	if o.quarantine != "" {
		if !quarantine_open(&qw, o.quarantine, stderr_w, alloc) {
			return EXIT_USAGE
		}
	}
	defer quarantine_close(&qw, stderr_w)

	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	has_in_files := len(o.files) > 0 || !o.null_input || (.Inputs in plan.serial) || (.Position in plan.serial)
	parallel_allowed := o.threads != 1 && (!cfg.to_tabular || can_direct_tabular(o, cfg, o.to_spec)) && !cfg.one_doc && cfg.to_render == .None && !o.unbuffered
	parallel_min_bytes := parallel_min_bytes_of(o)
	lazy_pool: host.Pool
	has_lazy_pool := false
	defer if has_lazy_pool {
		host.pool_destroy(&lazy_pool)
	}
	runner := (^tape.Runner)(nil)
	if parallel_allowed && (base_runner != nil || (o.threads > 1 && (o.explain || o.plan_out != "" || o.plan_file != ""))) {
		runner = ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o)
	}

	emit := engine.Emitter{fn = out_sink_emit, data = &osink}
	exit_code := EXIT_OK

	if o.each {
		exit_code = run_jq_each_files(o, cfg, &plan.contract, sh, worker, &osink, emit, &qw, &pin, paths, stdin_override, base_runner, &lazy_pool, &has_lazy_pool, parallel_allowed, parallel_min_bytes, stderr_w, alloc)
		if osink.failed {
			return report_out_stream_error(&osink, stderr_w)
		}
		if !out_stream_flush(&osink) {
			return report_out_stream_error(&osink, stderr_w)
		}
		if qw.write_failed {
			return EXIT_USAGE
		}
		return exit_code
	}

	if o.null_input {
		if !ensure_jq_tab_writer(o, cfg, worker, &osink, alloc) {
			return EXIT_RUNTIME
		}
		worker.hook_ctx = {
			o               = o,
			paths           = paths if has_in_files && len(o.files) > 0 else (fb[:] if (.Inputs in plan.serial) else nil),
			stdin_override  = stdin_override,
			raw_lines       = o.raw_input,
			stream_prog     = sh.stream_prog,
			stream_heap     = &worker.h,
			runner          = runner,
			xml_schema_desc = sh.xml_schema_desc,
			stderr_w        = stderr_w,
			alloc           = sh.locked_alloc,
		}
		defer {
			hook_ctx_close(&worker.hook_ctx)
			worker.hook_ctx.paths = nil
		}
		if o.explain || o.plan_out != "" || o.plan_file != "" {
			dec := engine.decide(&plan.contract, o.from_spec, .Single, {null_input = true, runner = runner, dups = o.dups, where_mode = o.where_mode})
			if o.explain {
				explain_decision(stderr_w, &plan.contract, &dec, alloc)
			}
			if pcode := plan_pin_apply(&pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
				return pcode
			}
		}
		worker.file_name = "<null>"
		ee := run_prog_on_value(worker, &worker.run, query.NULL, {file_path = "<null>"}, emit, cfg, true)
		merge_worker_outcome(sh, worker, {}, ee, true)
		flush_null := (ee == .None || (ee == .Halted && worker.halt_code == 0)) && !worker.hook_ctx.has_open_err
		if tcode := finish_jq_writers(worker, &osink, stderr_w, alloc, flush_render = flush_null); tcode != EXIT_OK && ee == .None {
			return tcode
		}
		if osink.failed || !out_stream_flush(&osink) {
			return report_out_stream_error(&osink, stderr_w)
		}
		if worker.hook_ctx.has_open_err {
			return EXIT_USAGE
		}
		return finalize_shared_status(o, sh, &osink, stderr_w, alloc)
	}

	if o.raw_input || o.slurp || o.stream {
		exit_code = run_jq_special(o, cfg, &plan.contract, sh, worker, &osink, emit, &qw, &pin, paths, stdin_override, runner, stderr_w, alloc)
		flush_sp := exit_code == EXIT_OK || (o.exit_status && exit_code == EXIT_FALSY)
		if tcode := finish_jq_writers(worker, &osink, stderr_w, alloc, flush_render = flush_sp); tcode != EXIT_OK && exit_code == EXIT_OK {
			exit_code = tcode
		}
		if osink.failed || !out_stream_flush(&osink) {
			return report_out_stream_error(&osink, stderr_w)
		}
		if qw.write_failed {
			return EXIT_USAGE
		}
		return exit_code
	}

	// Fast path: chunked streaming of NDJSON / `.Seq` directly from live stdin pipe!
	if len(paths) == 1 && paths[0] == "-" && stdin_override == nil {
		handled, bad_s, scode := stream_stdin_delim(o, cfg, &plan.contract, worker, &osink, emit, &qw, &pin, stderr_w, alloc)
		if handled {
			flush_st := scode == EXIT_OK && !(bad_s && o.skip_bad)
			if tcode := finish_jq_writers(worker, &osink, stderr_w, alloc, flush_render = flush_st); tcode != EXIT_OK && scode == EXIT_OK {
				scode = tcode
			}
			if osink.failed || !out_stream_flush(&osink) {
				return report_out_stream_error(&osink, stderr_w)
			}
			if qw.write_failed {
				return EXIT_USAGE
			}
			if scode != EXIT_OK {
				return scode
			}
			if bad_s && o.skip_bad {
				return EXIT_RUNTIME
			}
			return finalize_shared_status(o, sh, &osink, stderr_w, alloc)
		}
	}

	// Check `.Files_Parallel` eligibility when multiple homogeneous regular files are passed.
	same_spec := len(paths) > 1
	if same_spec {
		base_sp, _ := detect_file_spec(o, paths[0])
		for p in paths[1:] {
			psp, _ := detect_file_spec(o, p)
			if psp != base_sp {
				same_spec = false
				break
			}
		}
	}
	direct_guard := plan.contract.hints.projection.shape != .None && projection_direct_blocked(o, cfg, 1)
	can_files_par := len(paths) > 1 &&
		same_spec &&
		parallel_allowed &&
		plan.contract.serial == {} &&
		!cfg.to_tabular &&
		!cfg.one_doc &&
		cfg.to_render == .None &&
		!direct_guard &&
		!o.skip_bad &&
		!o.seq &&
		!o.where_mode &&
		!o.each &&
		o.xml_arrays == .Auto &&
		total_regular_bytes_small(o, paths, alloc)

	if can_files_par {
		finputs := make([]engine.File_Input, len(paths), alloc)
		loaded_n := 0
		open_failed := false
		for p, idx in paths {
			b, owned, rok := read_input_bytes(p, stdin_override, io.Writer{}, alloc)
			_ = owned
			if !rok {
				open_failed = true
				break
			}
			sp, fr := detect_file_spec(o, p)
			if e, ok_e := engine.entry_of_spec(sp); ok_e && e.id == .Json && fr == .Single {
				fr = .Concatenated
			}
			finputs[idx] = {path = p, src = b, spec = sp, framing = fr}
			loaded_n = idx + 1
		}
		if open_failed {
			for i in 0 ..< loaded_n {
				delete(finputs[i].src, alloc)
			}
			delete(finputs, alloc)
			// Fall back to sequential per-file loop so missing files don't block valid files!
		} else {
			defer {
				for fi in finputs {
					delete(fi.src, alloc)
				}
				delete(finputs, alloc)
			}
			runner = ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o)
			if o.explain || o.plan_out != "" || o.plan_file != "" {
				fdec, _ := decide_file_route(o, cfg, &plan.contract, finputs[0].spec, finputs[0].framing, len(finputs[0].src), runner, len(finputs), sh.each_prog != nil, sh.pred_prog != nil, stderr_w, alloc)
				if pcode := plan_pin_apply(&pin, &fdec, stderr_w, alloc); pcode != EXIT_OK {
					return pcode
				}
			}
			ro := read_opts_of(o, finputs[0].spec, runner)
			use_direct_par := plan.contract.hints.projection.shape != .None && !cfg.to_non_json && cfg.to_render == .None && !cfg.join && !cfg.raw0
			par_emit := engine.Emitter{fn = direct_nl_emit, data = &osink} if use_direct_par else emit
			sp_files := &plan.contract.hints.split
			has_count_files := sh.each_prog != nil && sp_files.kind == .Length && sp_files.has_each
			fast_each_files := sh.fast_json if ((sp_files.kind == .Stream || (sp_files.kind == .Collect && !sp_files.has_tail)) && !sp_files.has_each) else .None
			collect_compact_files := sp_files.kind == .Collect && !sp_files.has_tail && sh.collect_each && !o.raw && !o.join && !o.raw0 && !o.sort_keys && !o.ascii && o.compact && !cfg.color && !o.seq && !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.where_mode && !o.exit_status
			coalesce_files := !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.unbuffered && !o.each
			res := engine.execute_files(
				&plan.contract,
				finputs,
				{
					runner            = runner,
					where_mode        = o.where_mode,
					dups              = o.dups,
					allow_rerun_whole = true,
					serial_eval_ctx   = cfg.one_doc,
				},
				{
					eval                  = eval_jq_doc,
					eval_ctx              = worker,
					eval_each             = eval_jq_each if sh.each_prog != nil else nil,
					eval_each_ctx         = worker if sh.each_prog != nil else nil,
					eval_each_count       = eval_jq_each_count if has_count_files else nil,
					emit_spine_length     = emit_jq_spine_length if has_count_files else nil,
					pred_eval             = eval_jq_pred if sh.pred_prog != nil else nil,
					pred_ctx              = sh if sh.pred_prog != nil else nil,
					spine_collect         = eval_spine_collect if sh.tail_prog != nil else nil,
					workers               = {init = worker_hook_init, fini = worker_hook_fini},
					emit                  = par_emit,
					read                  = ro,
					runner                = runner,
					direct_out            = direct_out_of(o.to_spec),
					direct_csv_header     = !o.dsv_out.no_header,
					fast_json             = sh.fast_json if sh.ident_main else .None,
					fast_json_each        = fast_each_files,
					coalesce_emit         = coalesce_files,
					direct_append_nl      = coalesce_files,
					spine_collect_compact = collect_compact_files,
					eval_ctx_thread_safe  = true,
					rerun_whole_on_taint  = true,
					allocator             = sh.locked_alloc,
				},
			)
			if osink.failed || !out_stream_flush(&osink) {
				return report_out_stream_error(&osink, stderr_w)
			}
			err_fi := finputs[0]
			if res.err == .Read_Error {
				k, _ := find_files_read_error(o, &plan.contract, finputs, ro, sh.locked_alloc)
				err_fi = finputs[k]
			} else if res.err != .None && res.err != .Stopped {
				sync.mutex_lock(&sh.merge_lock)
				k := sh.merge.err_key.file_idx
				sync.mutex_unlock(&sh.merge_lock)
				if k >= 0 && k < len(finputs) {
					err_fi = finputs[k]
				}
			}
			return handle_shared_result(o, sh, worker, res, err_fi.path, err_fi.src, err_fi.spec, stderr_w, alloc)
		}
	}

	// Stream and execute ONE file at a time (freeing each buffer immediately before opening the next!).
	has_open_err := false
	has_exec_err := false
	had_bad := false

	bad_ctx: Quarantine_Bad_Ctx
	for p, fidx in paths {
		b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok {
			has_open_err = true
			continue
		}
		disp := "<stdin>" if p == "-" else p
		sp, fr := detect_file_spec(o, p)
		cur_runner := runner
		if cur_runner == nil && parallel_allowed && len(b) >= parallel_min_bytes {
			cur_runner = ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o)
		}
		res, pin_code := exec_jq_on_bytes(
			o,
			cfg,
			&plan.contract,
			sh,
			worker,
			&osink,
			emit,
			&qw,
			cur_runner,
			b,
			disp,
			sp,
			fr,
			fidx,
			len(paths),
			&bad_ctx,
			&pin,
			stderr_w,
			alloc,
		)
		if pin_code != EXIT_OK {
			if owned {
				delete(b, alloc)
			}
			_ = finish_jq_writers(worker, &osink, stderr_w, alloc, flush_render = false)
			if osink.failed || !out_stream_flush(&osink) {
				return report_out_stream_error(&osink, stderr_w)
			}
			return EXIT_USAGE if has_open_err else pin_code
		}
		if res.bad_records > 0 && o.skip_bad {
			had_bad = true
		}
		if res.err != .None && res.err != .Stopped {
			fcode := handle_shared_result(o, sh, worker, res, disp, b, sp, stderr_w, alloc)
			if owned {
				delete(b, alloc)
			}
			if res.err == .Halted {
				if tcode := finish_jq_writers(worker, &osink, stderr_w, alloc, flush_render = (fcode == EXIT_OK && !has_open_err)); tcode != EXIT_OK && fcode == EXIT_OK {
					fcode = tcode
				}
				if osink.failed || !out_stream_flush(&osink) {
					return report_out_stream_error(&osink, stderr_w)
				}
				return fcode
			}
			has_exec_err = true
			if !o.skip_bad {
				if tcode := finish_jq_writers(worker, &osink, stderr_w, alloc, flush_render = false); tcode != EXIT_OK && fcode == EXIT_OK {
					fcode = tcode
				}
				exit_code = EXIT_USAGE if has_open_err else fcode
				if osink.failed || !out_stream_flush(&osink) {
					return report_out_stream_error(&osink, stderr_w)
				}
				return exit_code
			}
		} else if owned {
			delete(b, alloc)
		}
		if osink.failed {
			return report_out_stream_error(&osink, stderr_w)
		}
	}

	flush_end := !has_open_err && !has_exec_err && !(had_bad && o.skip_bad) && !qw.write_failed
	if tcode := finish_jq_writers(worker, &osink, stderr_w, alloc, flush_render = flush_end); tcode != EXIT_OK {
		if osink.failed || !out_stream_flush(&osink) {
			return report_out_stream_error(&osink, stderr_w)
		}
		return tcode
	}
	if !out_stream_flush(&osink) {
		return report_out_stream_error(&osink, stderr_w)
	}
	if qw.write_failed {
		return EXIT_USAGE
	}
	if has_open_err {
		return EXIT_USAGE
	}
	if has_exec_err || (had_bad && o.skip_bad) {
		return EXIT_RUNTIME
	}
	return finalize_shared_status(o, sh, &osink, stderr_w, alloc)
}

@(private = "file")
Quarantine_Bad_Ctx :: struct {
	qw:          ^Quarantine_Writer,
	display:     string,
	src:         []u8,
	sp:          engine.Spec,
	ignoring:    bool,
	skip_active: bool,
	bad_cnt:     i64,
	stderr_w:    io.Writer,
	alloc:       runtime.Allocator,
}

@(private = "file")
ensure_lazy_pool :: proc(base_runner: ^tape.Runner, lazy: ^host.Pool, has_lazy: ^bool, o: ^Options) -> ^tape.Runner {
	if base_runner != nil {
		return base_runner
	}
	if !has_lazy^ {
		if host.pool_init(lazy, o.threads) != nil {
			return nil
		}
		has_lazy^ = true
	}
	return &lazy.runner
}

@(private = "file")
parallel_min_bytes_of :: #force_inline proc "contextless" (o: ^Options) -> int {
	base := min(engine.RECORDS_PARALLEL_FROM, engine.SPINE_PARALLEL_FROM)
	if o.threads <= 0 && engine.SPINE_PARALLEL_FROM > 0 {
		return max(base, 4 << 20)
	}
	return base
}

@(private = "file")
run_jq_each_files :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Jq_State,
	worker: ^Jq_Worker,
	osink: ^Out_Stream,
	emit: engine.Emitter,
	qw: ^Quarantine_Writer,
	pin: ^Plan_Pin_State,
	paths: []string,
	stdin_override: Maybe([]u8),
	base_runner: ^tape.Runner,
	lazy_pool: ^host.Pool,
	has_lazy_pool: ^bool,
	parallel_allowed: bool,
	parallel_min_bytes: int,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> int {
	show_labels := !o.no_filename && len(paths) > 1
	has_open_err := false
	worst := EXIT_OK
	runner := (^tape.Runner)(nil)
	if parallel_allowed && (base_runner != nil || (o.threads > 1 && (o.explain || o.plan_out != "" || o.plan_file != ""))) {
		runner = ensure_lazy_pool(base_runner, lazy_pool, has_lazy_pool, o)
	}

	for p in paths {
		single_path := [1]string{p}
		osink.file_label = p if show_labels else ""
		osink.open_line = false

		// Reset per-file `-e` and merge error state cleanly while keeping `cfg.docs_emitted` across the whole run.
		sync.mutex_lock(&sh.merge_lock)
		if sh.merge.err_msg != "" {
			delete(sh.merge.err_msg, sh.locked_alloc)
		}
		if sh.merge.halt_msg != "" {
			delete(sh.merge.halt_msg, sh.locked_alloc)
		}
		sh.merge = {}
		sync.mutex_unlock(&sh.merge_lock)

		fcode := EXIT_OK
		if o.null_input {
			if !ensure_jq_tab_writer(o, cfg, worker, osink, alloc) {
				return EXIT_RUNTIME
			}
			worker.hook_ctx = {
				o               = o,
				paths           = single_path[:],
				stdin_override  = stdin_override,
				raw_lines       = o.raw_input,
				stream_prog     = sh.stream_prog,
				stream_heap     = &worker.h,
				runner          = runner,
				xml_schema_desc = sh.xml_schema_desc,
				stderr_w        = stderr_w,
				alloc           = sh.locked_alloc,
			}
			if o.explain || o.plan_out != "" || o.plan_file != "" {
				dec := engine.decide(plan, o.from_spec, .Single, {null_input = true, runner = runner, dups = o.dups, where_mode = o.where_mode})
				if o.explain {
					explain_decision(stderr_w, plan, &dec, alloc)
				}
				if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
					hook_ctx_close(&worker.hook_ctx)
					worker.hook_ctx.paths = nil
					_ = finish_jq_writers(worker, osink, stderr_w, alloc, flush_render = false)
					return EXIT_USAGE if has_open_err else pcode
				}
			}
			worker.file_name = "<null>"
			ee := run_prog_on_value(worker, &worker.run, query.NULL, {file_path = "<null>"}, emit, cfg, true)
			merge_worker_outcome(sh, worker, {}, ee, true)
			if worker.hook_ctx.has_open_err {
				has_open_err = true
			}
			hook_ctx_close(&worker.hook_ctx)
			worker.hook_ctx.paths = nil
			fcode = finalize_shared_status(o, sh, osink, stderr_w, alloc)
			if ee == .Halted {
				_ = finish_jq_writers(worker, osink, stderr_w, alloc, flush_render = (fcode == EXIT_OK && !worker.hook_ctx.has_open_err))
				return fcode
			}
		} else if o.raw_input || o.slurp || o.stream {
			fcode = run_jq_special(o, cfg, plan, sh, worker, osink, emit, qw, pin, single_path[:], stdin_override, runner, stderr_w, alloc)
			if fcode == EXIT_USAGE {
				has_open_err = true
			}
		} else {
			b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
			if !rok {
				has_open_err = true
				_ = finish_jq_writers(worker, osink, stderr_w, alloc, flush_render = false)
				continue
			}
			disp := "<stdin>" if p == "-" else p
			sp, fr := detect_file_spec(o, p)
			cur_runner := runner
			if cur_runner == nil && parallel_allowed && len(b) >= parallel_min_bytes {
				cur_runner = ensure_lazy_pool(base_runner, lazy_pool, has_lazy_pool, o)
			}
			bad_ctx: Quarantine_Bad_Ctx
			res, pcode := exec_jq_on_bytes(o, cfg, plan, sh, worker, osink, emit, qw, cur_runner, b, disp, sp, fr, 0, 1, &bad_ctx, pin, stderr_w, alloc)
			if pcode != EXIT_OK {
				if owned {
					delete(b, alloc)
				}
				_ = finish_jq_writers(worker, osink, stderr_w, alloc, flush_render = false)
				return EXIT_USAGE if has_open_err else pcode
			}
			fcode = handle_shared_result(o, sh, worker, res, disp, b, sp, stderr_w, alloc)
			if owned {
				delete(b, alloc)
			}
			if res.err == .Halted {
				_ = finish_jq_writers(worker, osink, stderr_w, alloc, flush_render = (fcode == EXIT_OK))
				return fcode
			}
			if res.bad_records > 0 && o.skip_bad && fcode < EXIT_RUNTIME {
				fcode = EXIT_RUNTIME
			}
		}

		flush_file := (fcode == EXIT_OK || (o.exit_status && fcode == EXIT_FALSY)) && !worker.hook_ctx.has_open_err
		if tcode := finish_jq_writers(worker, osink, stderr_w, alloc, flush_render = flush_file); tcode != EXIT_OK && fcode == EXIT_OK {
			fcode = tcode
		}
		if fcode != EXIT_OK {
			worst = max(worst, fcode)
		}
		if osink.failed {
			return report_out_stream_error(osink, stderr_w)
		}
	}
	osink.file_label = ""
	if has_open_err {
		return EXIT_USAGE
	}
	return worst
}

@(private = "file")
emit_stream_err :: proc(w: ^Jq_Worker, err: tape.Error, disp: string, src: []u8, fmt_ptr: ^tape.Format, emit: engine.Emitter, cfg: ^Render_Config) {
	buf: [256]u8
	msg := tape.error_message(buf[:], err, src, fmt_ptr)
	arr, st := query.make_array(&w.h, 2)
	if st != .Ok {
		return
	}
	s, s1 := query.text_value(&w.h, msg)
	empty, s2 := query.make_array(&w.h, 0)
	if s1 != .Ok || s2 != .Ok {
		query.release(&w.h, s)
		query.release(&w.h, empty)
		query.release(&w.h, arr)
		return
	}
	_ = query.append_owned(&w.h, &arr, s)
	_ = query.append_owned(&w.h, &arr, empty)
	_ = run_prog_on_value(w, &w.run, arr, {file_path = disp}, emit, cfg, true)
}

@(private = "file")
run_jq_special :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Jq_State,
	w: ^Jq_Worker,
	osink: ^Out_Stream,
	emit: engine.Emitter,
	qw: ^Quarantine_Writer,
	pin: ^Plan_Pin_State,
	paths: []string,
	stdin_override: Maybe([]u8),
	runner: ^tape.Runner,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> int {
	if !ensure_jq_tab_writer(o, cfg, w, osink, alloc) {
		return EXIT_RUNTIME
	}
	if o.explain || o.plan_out != "" || o.plan_file != "" {
		sp, fr := detect_file_spec(o, paths[0] if len(paths) > 0 else "-")
		dec := engine.decide(plan, sp, fr, {runner = runner, slurp = o.slurp, raw_input = o.raw_input, dups = o.dups, where_mode = o.where_mode})
		if o.explain {
			explain_decision(stderr_w, plan, &dec, alloc)
		}
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
			return pcode
		}
	}
	if o.raw_input {
		if o.slurp {
			sb := strings.builder_make(alloc)
			defer strings.builder_destroy(&sb)
			has_open_err := false
			for p in paths {
				b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
				if !rok {
					has_open_err = true
					continue
				}
				_, _ = io.write(strings.to_writer(&sb), b)
				if owned {
					delete(b, alloc)
				}
			}
			sv, st := query.text_value(&w.h, strings.to_string(sb))
			if st != .Ok {
				return EXIT_RUNTIME
			}
			disp := "<stdin>" if (len(paths) == 0 || paths[0] == "-") else paths[0]
			ee := run_prog_on_value(w, &w.run, sv, {file_path = disp}, emit, cfg, true)
			merge_worker_outcome(sh, w, {}, ee, true)
			if has_open_err && ee != .Halted {
				return EXIT_USAGE
			}
			return finalize_shared_status(o, sh, osink, stderr_w, alloc)
		}
		has_open_err := false
		for p, fidx in paths {
			disp := "<stdin>" if p == "-" else p
			bs, ok := byte_stream_open(p, stdin_override, stderr_w, alloc)
			if !ok {
				has_open_err = true
				continue
			}
			idx := u64(0)
			nl_cnt := i64(0)
			for {
				line: string
				has, had_nl, err := byte_stream_next_raw_line(&bs, &line)
				if err != nil {
					byte_stream_close(&bs)
					fmt.wprintf(stderr_w, "stury: error: Could not read %s: %s\n", p, os.error_string(err))
					return EXIT_USAGE
				}
				if !has {
					break
				}
				if had_nl {
					nl_cnt += 1
				}
				sv, st := query.text_value(&w.h, line)
				if st != .Ok {
					byte_stream_close(&bs)
					return EXIT_RUNTIME
				}
				w.file_name = disp
				w.hook_ctx.file_path = disp
				w.hook_ctx.line_number = nl_cnt
				ee := run_prog_on_value(w, &w.run, sv, {file_path = disp, record_index = idx}, emit, cfg, true)
				merge_worker_outcome(sh, w, {file_idx = fidx, rec_idx = idx}, ee, true)
				if ee != .None {
					byte_stream_close(&bs)
					if ee == .Halted {
						return w.halt_code
					}
					if osink.failed {
						return report_out_stream_error(osink, stderr_w)
					}
					if ee == .Stopped {
						return EXIT_OK
					}
					return finalize_shared_status(o, sh, osink, stderr_w, alloc)
				}
				idx += 1
			}
			byte_stream_close(&bs)
		}
		if has_open_err {
			return EXIT_USAGE
		}
		return finalize_shared_status(o, sh, osink, stderr_w, alloc)
	}

	srun: jq.Run
	if o.stream && sh.stream_prog != nil {
		jq.run_init(&srun, sh.stream_prog, &w.h, nil)
	}
	defer if o.stream && sh.stream_prog != nil {
		jq.run_destroy(&srun)
	}

	arr := query.ABSENT
	if !o.stream {
		as: query.Status
		arr, as = query.make_array(&w.h, 8)
		if as != .Ok {
			return EXIT_RUNTIME
		}
	}
	defer if !o.stream && arr.kind != .Absent {
		query.release(&w.h, arr)
	}

	serr_mode := o.stream && o.stream_errors
	has_open_err := false
	had_bad := false
	for p, fidx in paths {
		b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok {
			has_open_err = true
			continue
		}
		disp := "<stdin>" if p == "-" else p
		sp, fr := detect_file_spec(o, p)
		e, _ := engine.entry_of_spec(sp)
		ro := read_opts_of(o, sp, nil)

		if !o.stream && (e.tabular || (fr == .Single && e.id != .Json)) {
			// For `-s` transfer `b` directly when owned so parse error printing never hits a freed buffer.
			dv, berr, dok := build_doc_val(&w.h, b, sp, ro, alloc, owns_src = owned, xml_arrays = o.xml_arrays, xml_desc = sh.xml_schema_desc)
			if berr != nil || !dok {
				code := print_tape_error(stderr_w, disp, berr, b, sp) if berr != nil else EXIT_RUNTIME
				if owned {
					delete(b, alloc)
				}
				return code
			}
			if e.tabular && query.type_of(dv) == .Array {
				if c, cs := query.cursor_open(&w.h, dv); cs == .Ok {
					for {
						ck, item, more, ns := query.cursor_next(&w.h, &c)
						if ns != .Ok || !more {
							break
						}
						query.release(&w.h, ck)
						_ = query.append_owned(&w.h, &arr, item)
					}
					query.cursor_close(&c)
				}
				query.release(&w.h, dv)
			} else {
				_ = query.append_owned(&w.h, &arr, dv)
			}
			continue
		}

		eff_fr := engine.Framing.Concatenated if (e.id == .Json && fr == .Single) else fr
		skip_recs := o.skip_bad || (eff_fr == .Seq && !serr_mode)
		it, iok := rec_loop_open(b, sp, eff_fr, ro, skip_recs, disp, io.Writer{} if serr_mode else stderr_w, alloc)
		if !iok {
			if serr_mode {
				emit_stream_err(w, it.open_err, disp, b, e.format, emit, cfg)
				if owned {
					delete(b, alloc)
				}
				continue
			}
			if owned {
				delete(b, alloc)
			}
			return EXIT_RUNTIME
		}

		rec_idx := i64(0)
		for rec, rinfo, rerr in rec_loop_next(&it) {
			rec_idx += 1
			if rerr != nil {
				if serr_mode {
					had_bad = true
					emit_stream_err(w, rerr, disp, b, e.format, emit, cfg)
					continue
				}
				if o.skip_bad || eff_fr == .Seq {
					if o.skip_bad {
						had_bad = true
					}
					_ = print_tape_error(stderr_w, disp, rerr, b, sp, ignoring = true)
					if qw != nil && qw.active {
						_ = quarantine_write_bad(qw, rec_idx, disp, rerr, rec, sp, alloc, b)
					}
					continue
				}
				rec_loop_close(&it)
				if owned {
					delete(b, alloc)
				}
				return print_tape_error(stderr_w, disp, rerr, b, sp)
			}
			rec_copy := slice.clone(rec, alloc)
			dv, berr, bok := build_doc_val(&w.h, rec_copy, sp, ro, alloc, owns_src = true, xml_arrays = o.xml_arrays, xml_desc = sh.xml_schema_desc)
			if berr != nil || !bok {
				delete(rec_copy, alloc)
				rec_loop_close(&it)
				if owned {
					delete(b, alloc)
				}
				return print_tape_error(stderr_w, disp, berr, rec, sp, false, b, rinfo.lo) if berr != nil else EXIT_RUNTIME
			}
			if !o.stream {
				_ = query.append_owned(&w.h, &arr, dv)
				continue
			}
			SBridge :: struct {
				sh:      ^Shared_Jq_State,
				w:       ^Jq_Worker,
				cfg:     ^Render_Config,
				display: string,
				fidx:    int,
				emit:    engine.Emitter,
				ee:      engine.Exec_Error,
			}
			sbr := SBridge{sh = sh, w = w, cfg = cfg, display = disp, fidx = fidx, emit = emit}
			_ = jq.run_value(&srun, dv, proc(d: rawptr, v: query.Value, _h: ^query.Heap) -> bool {
				sb := (^SBridge)(d)
				ee := run_prog_on_value(sb.w, &sb.w.run, v, {file_path = sb.display}, sb.emit, sb.cfg, true)
				merge_worker_outcome(sb.sh, sb.w, {file_idx = sb.fidx}, ee, true)
				if ee != .None {
					sb.ee = ee
					return false
				}
				return true
			}, &sbr)
			if sbr.ee != .None {
				rec_loop_close(&it)
				if owned {
					delete(b, alloc)
				}
				return finalize_shared_status(o, sh, osink, stderr_w, alloc)
			}
		}
		tail_err := it.tail_err
		rec_loop_close(&it)
		if tail_err != nil {
			if serr_mode {
				emit_stream_err(w, tail_err, disp, b, e.format, emit, cfg)
			} else {
				if owned {
					delete(b, alloc)
				}
				return EXIT_RUNTIME
			}
		}
		if owned {
			delete(b, alloc)
		}
	}

	if o.stream {
		if has_open_err {
			return EXIT_USAGE
		}
		return finalize_shared_status(o, sh, osink, stderr_w, alloc)
	}

	disp := "<stdin>" if (len(paths) == 0 || paths[0] == "-") else paths[0]
	run_arr := arr
	arr = query.ABSENT
	ee := run_prog_on_value(w, &w.run, run_arr, {file_path = disp}, emit, cfg, true)
	merge_worker_outcome(sh, w, {}, ee, true)
	if ee == .Halted {
		return finalize_shared_status(o, sh, osink, stderr_w, alloc)
	}
	if has_open_err {
		return EXIT_USAGE
	}
	if had_bad && o.skip_bad {
		return EXIT_RUNTIME
	}
	return finalize_shared_status(o, sh, osink, stderr_w, alloc)
}

@(private = "file")
finalize_shared_status :: proc(o: ^Options, sh: ^Shared_Jq_State, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	_ = alloc
	if osink != nil && osink.failed {
		return report_out_stream_error(osink, stderr_w)
	}
	sync.mutex_guard(&sh.merge_lock)
	m := &sh.merge
	if m.has_err {
		switch m.err_kind {
		case .None, .Stopped:
		case .Halted:
			if m.halt_msg != "" && stderr_w.procedure != nil {
				_, _ = io.write_string(stderr_w, m.halt_msg)
			}
			return m.halt_code
		case .Failed, .Tainted, .Read_Error, .Write_Error, .Unsupported, .No_Memory:
			if m.err_msg != "" && stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "jq: error: %s\n", m.err_msg)
			}
			return EXIT_RUNTIME
		}
	}
	if o.exit_status {
		if m.total_emitted == 0 {
			return EXIT_NO_OUTPUT
		}
		if m.last_falsy {
			return EXIT_FALSY
		}
	}
	return EXIT_OK
}

@(private = "file")
handle_shared_result :: proc(
	o: ^Options,
	sh: ^Shared_Jq_State,
	worker: ^Jq_Worker,
	res: engine.Exec_Result,
	file: string,
	src: []u8,
	sp: engine.Spec,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> int {
	_ = worker
	switch res.err {
	case .None, .Stopped:
		return finalize_shared_status(o, sh, sh.osink, stderr_w, alloc)
	case .Halted:
		sync.mutex_guard(&sh.merge_lock)
		if sh.merge.halt_msg != "" && stderr_w.procedure != nil {
			_, _ = io.write_string(stderr_w, sh.merge.halt_msg)
		}
		return sh.merge.halt_code
	case .Read_Error:
		return print_tape_error(stderr_w, file, res.read_err, src, sp)
	case .Write_Error:
		sync.mutex_guard(&sh.merge_lock)
		if sh.merge.err_msg != "" {
			fmt.wprintf(stderr_w, "stury: error: %s\n", sh.merge.err_msg)
			return EXIT_RUNTIME
		}
		msg := write_error_string(res.write_err, alloc)
		fmt.wprintf(stderr_w, "stury: error: %s\n", msg)
		delete(msg, alloc)
		return EXIT_RUNTIME
	case .Failed, .Tainted, .Unsupported, .No_Memory:
		sync.mutex_guard(&sh.merge_lock)
		msg := sh.merge.err_msg if (sh.merge.has_err && sh.merge.err_msg != "") else "execution failed"
		fmt.wprintf(stderr_w, "jq: error (at %s): %s\n", file, msg)
		return EXIT_RUNTIME
	}
	return EXIT_RUNTIME
}

// ---- RFC 9535 JSONPath Engine Integration ----

@(private = "file")
Shared_Jp_State :: struct {
	o:                 ^Options,
	cfg:               ^Render_Config,
	prog:              ^jsonpath.Program,
	where_mode:        bool,
	budget:            tape.Budget,
	osink:             ^Out_Stream,
	serial_worker:     ^Jp_Worker,
	direct_tab:        Direct_Tab_Sink,
	direct_tab_bytes:  u64,
	direct_tab_active: bool,
	stderr_w:          io.Writer,
	alloc:             runtime.Allocator,
	alloc_lock:        sync.Mutex,
	locked_alloc:      runtime.Allocator,
	pool_lock:         sync.Mutex,
	free_workers:      [dynamic]^Jp_Worker,
	merge_lock:        sync.Mutex,
	merge:             Merge_State,
	xml_schema_desc:   ^rules.Description,
}

@(private = "file")
Jp_Worker :: struct {
	shared:       ^Shared_Jp_State,
	prog:         ^jsonpath.Program,
	h:            query.Heap,
	run:          jsonpath.Run,
	cfg:          ^Render_Config,
	budget:       tape.Budget,
	where_mode:   bool,
	last_falsy:   bool,
	out_count:    u64,
	nul_err:      bool,
	err_msg:      string,
	scratch:      [dynamic]u8,
	where_sb:     strings.Builder,
	tw:           ^write.Table_Writer,
	rtw:          ^Render_Table_Writer,
	file_name:    string,
	is_exclusive: bool,
	alloc:        runtime.Allocator,
}

@(private = "file")
new_jp_worker :: proc(sh: ^Shared_Jp_State, alloc: runtime.Allocator, exclusive: bool) -> ^Jp_Worker {
	w := new(Jp_Worker, alloc)
	w^ = {
		shared       = sh,
		prog         = sh.prog,
		cfg          = sh.cfg,
		budget       = sh.budget,
		where_mode   = sh.where_mode,
		scratch      = make([dynamic]u8, 0, 256, alloc),
		where_sb     = strings.builder_make(alloc),
		is_exclusive = exclusive,
		alloc        = alloc,
	}
	query.heap_init(&w.h, alloc, memory_limit = sh.budget.memory, depth = int(sh.budget.depth))
	w.h.keep_origins = sh.where_mode
	jsonpath.run_init(&w.run, sh.prog, &w.h, {want_paths = sh.where_mode, budget = sh.budget})
	return w
}

@(private = "file")
free_jp_worker :: proc(w: ^Jp_Worker) {
	if w == nil {
		return
	}
	a := w.alloc
	jsonpath.run_destroy(&w.run)
	delete(w.scratch)
	strings.builder_destroy(&w.where_sb)
	if w.err_msg != "" {
		delete(w.err_msg, a)
	}
	if w.tw != nil {
		tw_alloc := w.tw.allocator if w.tw.allocator.procedure != nil else a
		write.table_writer_drop(w.tw)
		free(w.tw, tw_alloc)
		w.tw = nil
	}
	if w.rtw != nil {
		rtw_alloc := w.rtw.allocator if w.rtw.allocator.procedure != nil else a
		render_table_writer_drop(w.rtw)
		free(w.rtw, rtw_alloc)
		w.rtw = nil
	}
	query.heap_destroy(&w.h)
	free(w, a)
}

@(private = "file")
jp_locked_alloc_fn :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	sh := (^Shared_Jp_State)(data)
	sync.mutex_guard(&sh.alloc_lock)
	return sh.alloc.procedure(sh.alloc.data, mode, size, alignment, old_ptr, old_size, loc)
}

@(private = "file")
eval_jp_doc :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	w := (^Jp_Worker)(ctx)
	if w == nil {
		return .No_Memory
	}
	sh := w.shared
	cur_w := w
	acquired := false
	if !w.is_exclusive {
		sync.mutex_lock(&sh.pool_lock)
		if len(sh.free_workers) > 0 {
			cur_w = pop(&sh.free_workers)
		} else {
			cur_w = nil
		}
		sync.mutex_unlock(&sh.pool_lock)
		if cur_w == nil {
			cur_w = new_jp_worker(sh, sh.locked_alloc, true)
		}
		cur_w.file_name = meta.file_path if meta.file_path != "" else w.file_name
		acquired = true
	}
	defer if acquired {
		if cur_w.err_msg != "" {
			delete(cur_w.err_msg, cur_w.alloc)
			cur_w.err_msg = ""
		}
		sync.mutex_guard(&sh.pool_lock)
		append(&sh.free_workers, cur_w)
	}

	cur_w.h.keep_origins = cur_w.where_mode
	cur_w.h.tainted = false
	query.clear_error(&cur_w.h)
	cur_w.out_count = 0
	cur_w.last_falsy = false
	cur_w.nul_err = false
	if cur_w.err_msg != "" {
		delete(cur_w.err_msg, cur_w.alloc)
		cur_w.err_msg = ""
	}

	if len(doc.nodes) > 0 && sh.o.xml_arrays == .Schema && sh.xml_schema_desc != nil && doc.format != nil && doc.format.options == .Xml {
		if nerr := engine.apply_xml_arrays(doc, .Schema, sh.xml_schema_desc, cur_w.alloc); nerr != nil {
			cur_w.err_msg = strings.clone("XML array normalization failed", cur_w.alloc)
			return .Failed
		}
	}

	inp, st := query.document_value(&cur_w.h, doc^, owned = false)
	if st != .Ok {
		return .Failed
	}
	defer query.release(&cur_w.h, inp)

	Jp_Bridge :: struct {
		w:    ^Jp_Worker,
		meta: engine.Record_Meta,
		emit: engine.Emitter,
		err:  engine.Exec_Error,
	}
	was_unwritten := sh.direct_tab_active && cur_w == sh.serial_worker && sh.osink.total_written == sh.direct_tab_bytes
	br := Jp_Bridge{w = cur_w, meta = meta, emit = emit}
	end := jsonpath.run_value(&cur_w.run, inp, proc(d: rawptr, val: query.Value, norm_path: string) -> bool {
		b := (^Jp_Bridge)(d)
		defer query.release(&b.w.h, val)
		vt := query.type_of(val)
		b.w.out_count += 1
		b.w.last_falsy = (vt == .Null || vt == .False || vt == .Absent)
		sh := b.w.shared
		if b.w.cfg.to_tabular {
			if b.w.tw == nil {
				if sh != nil && b.w == sh.serial_worker && b.w.alloc.procedure != nil {
					no_hdr := sh.direct_tab_active && sh.osink.total_written > sh.direct_tab_bytes
					tw, tok := start_tab_writer(sh.o, b.w.cfg, out_stream_writer(sh.osink), b.w.alloc, force_no_header = no_hdr)
					if !tok {
						b.w.err_msg = strings.clone("cannot start tabular writer", b.w.alloc)
						b.err = .Write_Error
						return false
					}
					b.w.tw = tw
				} else {
					b.w.err_msg = strings.clone("tabular output requires serial execution", b.w.alloc)
					b.err = .Write_Error
					return false
				}
			}
			if !write_table_row(&b.w.h, val, b.w.tw) {
				err := b.w.tw.err if b.w.tw.err != nil else write.Error(write.Refused{why = .Not_A_Table})
				b.w.err_msg = write_error_string(err, b.w.alloc)
				b.err = .Write_Error
				return false
			}
			return true
		}
		if b.w.cfg.to_render != .None {
			if b.w.rtw == nil {
				if sh != nil && b.w == sh.serial_worker && b.w.alloc.procedure != nil {
					rtw, rok := start_render_writer(sh.o, b.w.cfg, out_stream_writer(sh.osink), b.w.alloc)
					if !rok {
						b.w.err_msg = strings.clone("cannot start table renderer", b.w.alloc)
						b.err = .Write_Error
						return false
					}
					b.w.rtw = rtw
				} else {
					b.w.err_msg = strings.clone("table/markdown output requires serial execution", b.w.alloc)
					b.err = .Write_Error
					return false
				}
			}
			if !render_table_writer_value(b.w.rtw, &b.w.h, val) {
				if b.w.h.tainted {
					b.err = .Tainted
				} else {
					err := b.w.rtw.err if b.w.rtw.err != nil else write.Error(write.Refused{why = .No_Spelling})
					if ioe, is_io := err.(io.Error); is_io {
						sh.osink.failed = true
						sh.osink.io_err = ioe
						b.err = .Stopped
					} else {
						b.w.err_msg = write_error_string(err, b.w.alloc)
						b.err = .Write_Error
					}
				}
				return false
			}
			return true
		}
		if b.w.cfg.to_non_json {
			if b.w.cfg.one_doc && sync.atomic_load(&b.w.cfg.docs_emitted) >= 1 {
				b.w.err_msg = fmt.aprintf("--to %s writes one document: the filter gave a second output; collect the outputs into one value with [...]", b.w.cfg.to_name, allocator = b.w.alloc)
				b.err = .Write_Error
				return false
			}
			clear(&b.w.scratch)
			ew: Emit_Writer
			emit_writer_init(&ew, b.emit)
			ok, emsg := write_value_as_format(&b.w.h, val, b.w.cfg.to_spec, b.w.cfg.write_opts, &b.w.scratch, emit_writer_io(&ew), int(b.w.budget.depth), b.w.alloc)
			if !ok {
				if b.w.h.tainted {
					b.err = .Tainted
				} else if ew.stopped {
					b.err = .Stopped
				} else {
					b.w.err_msg = emsg
					b.err = .Write_Error
				}
				return false
			}
			e, _ := engine.entry_of_spec(b.w.cfg.to_spec)
			if !e.binary && (!ew.wrote_any || ew.last_byte != '\n') {
				nl := [1]u8{'\n'}
				_, _ = io.write(emit_writer_io(&ew), nl[:])
			}
			if !emit_writer_flush(&ew) {
				b.err = .Stopped
				return false
			}
			if b.w.cfg.one_doc {
				_ = sync.atomic_add(&b.w.cfg.docs_emitted, 1)
			}
			return true
		}
		prefix: []u8
		if b.w.where_mode {
			fn := b.meta.file_path if b.meta.file_path != "" else b.w.file_name
			prefix = build_where_prefix(&b.w.where_sb, &b.w.h, val, fn, norm_path)
		}
		rst, stopped := render_value_to_emitter(&b.w.h, val, b.w.cfg, prefix, &b.w.scratch, b.emit, b.emit.fn == out_sink_emit, &b.w.nul_err)
		if stopped {
			b.err = .Stopped
			return false
		}
		if rst != .Ok {
			if b.w.h.tainted {
				b.err = .Tainted
			} else if b.w.nul_err {
				b.w.err_msg = strings.clone("Cannot dump a string containing NUL with --raw-output0 option", b.w.alloc)
				b.err = .Failed
			} else {
				b.err = .Failed
			}
			return false
		}
		_ = sh
		return true
	}, &br)

	ret := br.err
	if ret == .None {
		switch end {
		case .Done:
		case .Stopped:
			ret = .Stopped
		case .Tainted:
			ret = .Tainted
		case .Exceeded, .Failed:
			ret = .Failed
		}
	}
	if sh.direct_tab_active && cur_w == sh.serial_worker && cur_w.tw != nil {
		tcode := finish_tab_writer(cur_w.tw, sh.osink, sh.stderr_w, cur_w.alloc)
		cur_w.tw = nil
		if tcode != EXIT_OK && (ret == .None || ret == .Stopped) {
			ret = .Stopped if sh.osink.failed else .Write_Error
		} else if was_unwritten && sh.osink.total_written > sh.direct_tab_bytes && !sh.o.dsv_out.no_header {
			sh.direct_tab.suppress_next_hdr = true
		}
	}
	if ret != .Tainted {
		sync.mutex_guard(&sh.merge_lock)
		m := &sh.merge
		key := Order_Key{file_idx = meta.file_index, rec_idx = meta.record_index}
		if cur_w.out_count > 0 {
			m.total_emitted += cur_w.out_count
			if !m.has_last || key_ge(key, m.last_key) {
				m.has_last = true
				m.last_key = key
				m.last_falsy = cur_w.last_falsy
			}
		}
		if ret != .None && ret != .Stopped && (!m.has_err || key_lt(key, m.err_key)) {
			m.has_err = true
			m.err_key = key
			m.err_kind = ret
			if m.err_msg != "" {
				delete(m.err_msg, sh.locked_alloc)
			}
			m.err_msg = strings.clone(cur_w.err_msg, sh.locked_alloc) if cur_w.err_msg != "" else ""
		}
	}
	return ret
}

@(private = "file")
run_jsonpath_query :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	base_runner: ^tape.Runner,
	alloc: runtime.Allocator,
) -> int {
	jp_src := o.filter.? or_else "$"
	prog, cerr := jsonpath.compile(jp_src, {max_depth = int(o.budget.depth)}, alloc)
	defer jsonpath.destroy_program(prog)
	if cerr.kind != .None {
		jp_bytes := transmute([]u8)jp_src
		off := u64(max(cerr.offset, 0))
		pl := tape.offset_place(jp_bytes, nil, off)
		snip_buf: [1024]u8
		if snip, has_snip := tape.error_snippet(snip_buf[:], jp_bytes, off); has_snip {
			fmt.wprintf(stderr_w, "stury: jsonpath error: <jsonpath>:%d:%d: %s\n%s", pl.line, pl.col, cerr.message, snip)
		} else {
			fmt.wprintf(stderr_w, "stury: jsonpath error: <jsonpath>:%d:%d: %s\n", pl.line, pl.col, cerr.message)
		}
		return EXIT_COMPILE
	}

	pin: Plan_Pin_State
	if !plan_pin_init(&pin, o, stderr_w, alloc) {
		return EXIT_USAGE
	}
	defer plan_pin_destroy(&pin)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, cfg.color)

	xml_sc: ^schema.Compiled
	if o.xml_arrays == .Schema && o.schema_file != "" {
		sc_ok: bool
		xml_sc, _, sc_ok = compile_schema_file(o, o.schema_file, stderr_w, alloc)
		if !sc_ok {
			return EXIT_USAGE
		}
	}
	defer schema.destroy(xml_sc)

	sh := Shared_Jp_State {
		o               = o,
		cfg             = cfg,
		prog            = prog,
		where_mode      = o.where_mode,
		budget          = o.budget,
		osink           = &osink,
		stderr_w        = stderr_w,
		alloc           = alloc,
		xml_schema_desc = xml_sc.description if xml_sc != nil else nil,
	}
	sh.locked_alloc = alloc if is_thread_safe_heap(alloc) else runtime.Allocator{procedure = jp_locked_alloc_fn, data = &sh}
	sh.free_workers = make([dynamic]^Jp_Worker, sh.locked_alloc)
	defer {
		for fw in sh.free_workers {
			free_jp_worker(fw)
		}
		delete(sh.free_workers)
		if sh.merge.err_msg != "" {
			delete(sh.merge.err_msg, sh.locked_alloc)
		}
	}

	worker := new_jp_worker(&sh, sh.locked_alloc, true)
	sh.serial_worker = worker
	defer free_jp_worker(worker)

	jp_worker_init :: proc(p: rawptr, _: int, _: runtime.Allocator) -> rawptr {
		pa := (^Jp_Worker)(p)
		if pa == nil || pa.shared == nil {
			return nil
		}
		sh := pa.shared
		sync.mutex_lock(&sh.pool_lock)
		if len(sh.free_workers) > 0 {
			c := pop(&sh.free_workers)
			sync.mutex_unlock(&sh.pool_lock)
			c.file_name = pa.file_name
			return c
		}
		sync.mutex_unlock(&sh.pool_lock)
		c := new_jp_worker(sh, sh.locked_alloc, true)
		c.file_name = pa.file_name
		return c
	}

	jp_worker_fini :: proc(_: rawptr, _: int, w: rawptr) {
		jp := (^Jp_Worker)(w)
		if jp == nil || jp.shared == nil {
			return
		}
		if jp.err_msg != "" {
			delete(jp.err_msg, jp.alloc)
			jp.err_msg = ""
		}
		jp.file_name = ""
		jp.tw = nil
		jp.rtw = nil
		sync.mutex_guard(&jp.shared.pool_lock)
		append(&jp.shared.free_workers, jp)
	}

	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	parallel_allowed := o.threads != 1 && (!cfg.to_tabular || can_direct_tabular(o, cfg, o.to_spec)) && !cfg.one_doc && cfg.to_render == .None && !o.unbuffered
	parallel_min_bytes := parallel_min_bytes_of(o)
	lazy_pool: host.Pool
	has_lazy_pool := false
	defer if has_lazy_pool {
		host.pool_destroy(&lazy_pool)
	}
	runner := (^tape.Runner)(nil)
	if parallel_allowed && (base_runner != nil || (o.threads > 1 && (o.explain || o.plan_out != "" || o.plan_file != ""))) {
		runner = ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o)
	}
	emit := engine.Emitter{fn = out_sink_emit, data = &osink}
	has_open_err := false

	for p, fidx in paths {
		b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok {
			has_open_err = true
			continue
		}
		disp := "<stdin>" if p == "-" else p
		sp, fr := detect_file_spec(o, p)
		cur_runner := runner
		if cur_runner == nil && parallel_allowed && len(b) >= parallel_min_bytes {
			cur_runner = ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o)
		}
		ro := read_opts_of(o, sp, cur_runner)
		worker.file_name = disp
		dec, eff_fr := decide_file_route(o, cfg, &prog.plan, sp, fr, len(b), cur_runner, 1, false, false, stderr_w, alloc, total_files = len(paths))
		if dec.kind == .Projection_Direct && cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed {
			fallback_non_direct_route(&dec, o, cfg, &prog.plan, cur_runner, len(b))
		}
		can_fallback_concat := eff_fr == .Single && dec.entry.id == .Json
		pin_active := pin.has_expected || pin.out_path != ""
		pin_applied := false
		if pin_active && !can_fallback_concat {
			if pcode := plan_pin_apply(&pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
				if owned {
					delete(b, alloc)
				}
				_ = finish_jp_writers(worker, &osink, stderr_w, alloc, flush_render = false)
				if osink.failed || !out_stream_flush(&osink) {
					return report_out_stream_error(&osink, stderr_w)
				}
				return EXIT_USAGE if has_open_err else pcode
			}
			pin_applied = true
		} else if pin_active && pin.has_expected && !engine.compare_plan_pin(pin.expected, engine.plan_pin_of(&dec)) {
			cand2 := engine.decide(&prog.plan, sp, .Concatenated, {
				runner            = cur_runner,
				where_mode        = o.where_mode,
				dups              = o.dups,
				file_count        = 1,
				input_bytes       = len(b),
				allow_rerun_whole = true,
				serial_eval_ctx   = cfg.one_doc || cfg.to_tabular || cfg.to_render != .None,
			})
			if cand2.kind == .Projection_Direct && (projection_direct_blocked(o, cfg, len(paths)) || (cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed)) {
				fallback_non_direct_route(&cand2, o, cfg, &prog.plan, cur_runner, len(b))
			}
			if !engine.compare_plan_pin(pin.expected, engine.plan_pin_of(&cand2)) || engine.validate(b, sp, ro, alloc) == nil {
				if pcode := plan_pin_apply(&pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
					if owned {
						delete(b, alloc)
					}
					_ = finish_jp_writers(worker, &osink, stderr_w, alloc, flush_render = false)
					if osink.failed || !out_stream_flush(&osink) {
						return report_out_stream_error(&osink, stderr_w)
					}
					return EXIT_USAGE if has_open_err else pcode
				}
				pin_applied = true
			}
		}
		use_direct := dec.kind == .Projection_Direct
		if use_direct && cfg.to_tabular && worker.tw != nil && len(paths) == 1 && !worker.tw.stream.headed {
			_ = finish_tab_writer(worker.tw, &osink, stderr_w, alloc)
			worker.tw = nil
		}
		if !use_direct && cfg.to_tabular && worker.tw == nil {
			tw, tok := start_tab_writer(o, cfg, out_stream_writer(&osink), alloc)
			if !tok {
				if owned {
					delete(b, alloc)
				}
				return EXIT_RUNTIME
			}
			worker.tw = tw
		}
		sh.direct_tab = {osink = &osink}
		eff_emit := emit
		if use_direct {
			if cfg.to_tabular {
				sh.direct_tab_bytes = osink.total_written
				sh.direct_tab_active = true
				eff_emit = engine.Emitter{fn = direct_tab_nl_emit, data = &sh.direct_tab}
			} else {
				eff_emit = engine.Emitter{fn = direct_nl_emit, data = &osink}
			}
		}
		jopts := engine.Exec_Options{
			eval                 = eval_jp_doc,
			eval_ctx             = worker,
			workers              = {init = jp_worker_init, fini = jp_worker_fini},
			emit                 = eff_emit,
			read                 = ro,
			runner               = cur_runner,
			direct_out           = direct_out_of(o.to_spec),
			direct_csv_header    = !o.dsv_out.no_header,
			eval_ctx_thread_safe = true,
			rerun_whole_on_taint = true,
			file_index           = fidx,
			file_path            = disp,
			allocator            = sh.locked_alloc,
		}
		res := engine.execute(&prog.plan, &dec, b, jopts)
		sh.direct_tab_active = false
		sh.direct_tab.suppress_next_hdr = false
		if res.err == .Read_Error && res.emitted == 0 && eff_fr == .Single {
			if fe, ok_e := engine.entry_of_spec(sp); ok_e && fe.id == .Json {
				if f, is_f := res.read_err.(tape.Fault); is_f && f.kind == .Bad_Char {
					dec2 := engine.decide(&prog.plan, sp, .Concatenated, {
						runner            = cur_runner,
						where_mode        = o.where_mode,
						dups              = o.dups,
						file_count        = 1,
						input_bytes       = len(b),
						allow_rerun_whole = true,
						serial_eval_ctx   = cfg.one_doc || cfg.to_tabular || cfg.to_render != .None,
					})
					if dec2.kind == .Projection_Direct && (projection_direct_blocked(o, cfg, len(paths)) || (cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed)) {
						fallback_non_direct_route(&dec2, o, cfg, &prog.plan, cur_runner, len(b))
					}
					if pin_active {
						if pcode := plan_pin_apply(&pin, &dec2, stderr_w, alloc); pcode != EXIT_OK {
							if owned {
								delete(b, alloc)
							}
							_ = finish_jp_writers(worker, &osink, stderr_w, alloc, flush_render = false)
							if osink.failed || !out_stream_flush(&osink) {
								return report_out_stream_error(&osink, stderr_w)
							}
							return EXIT_USAGE if has_open_err else pcode
						}
						pin_applied = true
					}
					use_direct2 := dec2.kind == .Projection_Direct
					if !use_direct2 && cfg.to_tabular && worker.tw == nil {
						tw, tok := start_tab_writer(o, cfg, out_stream_writer(&osink), alloc)
						if !tok {
							if owned {
								delete(b, alloc)
							}
							return EXIT_RUNTIME
						}
						worker.tw = tw
					}
					jopts2 := jopts
					if use_direct2 {
						if cfg.to_tabular {
							sh.direct_tab_bytes = osink.total_written
							sh.direct_tab_active = true
							jopts2.emit = engine.Emitter{fn = direct_tab_nl_emit, data = &sh.direct_tab}
						} else {
							jopts2.emit = engine.Emitter{fn = direct_nl_emit, data = &osink}
						}
					} else {
						jopts2.emit = emit
					}
					res = engine.execute(&prog.plan, &dec2, b, jopts2)
					sh.direct_tab_active = false
					sh.direct_tab.suppress_next_hdr = false
				}
			}
		}
		if pin_active && !pin_applied {
			if pcode := plan_pin_apply(&pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
				if owned {
					delete(b, alloc)
				}
				_ = finish_jp_writers(worker, &osink, stderr_w, alloc, flush_render = false)
				if osink.failed || !out_stream_flush(&osink) {
					return report_out_stream_error(&osink, stderr_w)
				}
				return EXIT_USAGE if has_open_err else pcode
			}
		}
		if res.err != .None && res.err != .Stopped {
			if res.err == .Read_Error {
				_ = print_tape_error(stderr_w, disp, res.read_err, b, sp)
			} else if sh.merge.err_msg != "" {
				fmt.wprintf(stderr_w, "stury: error (%s): %s\n", disp, sh.merge.err_msg)
			} else {
				fmt.wprintf(stderr_w, "stury: jsonpath runtime error (%s)\n", disp)
			}
			if owned {
				delete(b, alloc)
			}
			_ = finish_jp_writers(worker, &osink, stderr_w, alloc, flush_render = false)
			if osink.failed || !out_stream_flush(&osink) {
				return report_out_stream_error(&osink, stderr_w)
			}
			return EXIT_USAGE if has_open_err else EXIT_RUNTIME
		}
		if owned {
			delete(b, alloc)
		}
		if osink.failed {
			return report_out_stream_error(&osink, stderr_w)
		}
	}
	if tcode := finish_jp_writers(worker, &osink, stderr_w, alloc, flush_render = !has_open_err); tcode != EXIT_OK {
		if osink.failed || !out_stream_flush(&osink) {
			return report_out_stream_error(&osink, stderr_w)
		}
		return tcode
	}
	if !out_stream_flush(&osink) {
		return report_out_stream_error(&osink, stderr_w)
	}
	if has_open_err {
		return EXIT_USAGE
	}
	if o.exit_status {
		if sh.merge.total_emitted == 0 {
			return EXIT_NO_OUTPUT
		}
		if sh.merge.last_falsy {
			return EXIT_FALSY
		}
	}
	return EXIT_OK
}
