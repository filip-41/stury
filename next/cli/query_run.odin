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
import "stury:lib/query"
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

// Unified immutable per-run shared state for both jq and JSONPath queries.
Shared_Query_State :: struct {
	is_jp:             bool,
	o:                 ^Options,
	cfg:               ^Render_Config,
	jp_prog:           ^jsonpath.Program,
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
	serial_worker:     ^Query_Worker,
	direct_tab:        Direct_Tab_Sink,
	direct_tab_bytes:  u64,
	direct_tab_active: bool,
	stderr_w:          io.Writer,
	stderr_lock:       sync.Mutex,
	alloc:             runtime.Allocator,
	alloc_lock:        sync.Mutex,
	locked_alloc:      runtime.Allocator,
	pool_lock:         sync.Mutex,
	free_workers:      [dynamic]^Query_Worker,
	merge_lock:        sync.Mutex,
	merge:             Merge_State,
	xml_schema_desc:   ^engine.Schema_Description,
}

@(private = "file")
Hook_Ctx :: struct {
	o:               ^Options,
	paths:           []string,
	stdin_override:  Maybe([]u8),
	file_idx:        int,
	file_path:       string,
	line_number:     i64,
	raw_lines:       bool,
	raw_stream:      Byte_Stream,
	stream_open:     bool,
	file_buf:        []u8,
	file_buf_owned:  bool,
	cur_spec:        engine.Spec,
	cur_framing:     engine.Framing,
	cur_tabular:     bool,
	dsv_header:      []u8,
	recs_open:       bool,
	rec_loop:        Rec_Loop,
	single_done:     bool,
	has_open_err:    bool,
	stream_prog:     ^jq.Program,
	stream_heap:     ^query.Heap,
	stream_events:   [dynamic]query.Value,
	stream_idx:      int,
	runner:          ^tape.Runner,
	xml_schema_desc: ^engine.Schema_Description,
	stderr_w:        io.Writer,
	alloc:           runtime.Allocator,
}

@(private = "file")
Jq_Bridge :: struct {
	w:             ^Query_Worker,
	meta:          engine.Record_Meta,
	emit:          engine.Emitter,
	cfg:           ^Render_Config,
	allow_tabular: bool,
	err:           engine.Exec_Error,
}

@(private = "file")
Jp_Bridge :: struct {
	w:    ^Query_Worker,
	meta: engine.Record_Meta,
	emit: engine.Emitter,
	err:  engine.Exec_Error,
}

// Unified per-worker state for both jq and JSONPath execution.
Query_Worker :: struct {
	shared:       ^Shared_Query_State,
	hooks:        jq.Hooks,
	hook_ctx:     Hook_Ctx,
	h:            query.Heap,
	run:          jq.Run,
	each_run:     jq.Run,
	pred_run:     jq.Run,
	jp_run:       jsonpath.Run,
	jq_bridge:    Jq_Bridge,
	jp_bridge:    Jp_Bridge,
	has_each_run: bool,
	has_pred_run: bool,
	globals:      []query.Value,
	scratch:      [dynamic]u8,
	where_sb:     strings.Builder,
	tw:           ^engine.Write_Table_Writer,
	rtw:          ^Render_Table_Writer,
	file_name:    string,
	err_msg:      string,
	halt_msg:     string,
	has_halt:     bool,
	halt_code:    int,
	last_falsy:   bool,
	out_count:    u64,
	nul_err:      bool,
	is_exclusive: bool,
	alloc:        runtime.Allocator,
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

@(private = "file")
emit_writer_flush :: proc(ew: ^Emit_Writer) -> bool {
	if ew.stopped { return false }
	if ew.cursor > 0 {
		n := ew.cursor
		ew.cursor = 0
		if !engine.emit_bytes(ew.emit, ew.buf[:n]) {
			ew.stopped = true
			return false
		}
	}
	return true
}

@(private = "file")
emit_writer_io :: proc(ew: ^Emit_Writer) -> io.Writer {
	stream_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		w := (^Emit_Writer)(data)
		#partial switch mode {
		case .Query: return io.query_utility({.Write, .Flush})
		case .Flush:
			if emit_writer_flush(w) { return 0, .None }
			return 0, .Unexpected_EOF
		case .Write:
			if w.stopped { return 0, .Unexpected_EOF }
			for rem := p; len(rem) > 0; {
				if w.cursor == len(w.buf) && !emit_writer_flush(w) { return 0, .Unexpected_EOF }
				if w.cursor == 0 && len(rem) >= len(w.buf) {
					w.last_byte, w.wrote_any = rem[len(rem) - 1], true
					if !engine.emit_bytes(w.emit, rem) { w.stopped = true; return 0, .Unexpected_EOF }
					return i64(len(p)), .None
				}
				take := min(len(w.buf) - w.cursor, len(rem))
				copy(w.buf[w.cursor:], rem[:take])
				w.cursor += take
				w.last_byte, w.wrote_any = rem[take - 1], true
				rem = rem[take:]
			}
			return i64(len(p)), .None
		}
		return 0, .Empty
	}
	return io.Writer{procedure = stream_proc, data = ew}
}

@(private = "file")
key_lt :: proc "contextless" (a, b: Order_Key) -> bool {
	return a.file_idx < b.file_idx || (a.file_idx == b.file_idx && a.rec_idx < b.rec_idx)
}

build_doc_val :: proc(
	h: ^query.Heap,
	bytes: []u8,
	sp: engine.Spec,
	ro: tape.Options,
	alloc: runtime.Allocator,
	owns_src := false,
	xml_arrays := tape.Xml_Arrays.Auto,
	xml_desc: ^engine.Schema_Description = nil,
) -> (val: query.Value, berr: tape.Error, mem_ok: bool) {
	doc, err := engine.build(bytes, sp, ro, alloc)
	if err != nil { return query.NULL, err, true }
	if xml_arrays == .Schema && xml_desc != nil {
		if e, ok := engine.entry_of_spec(sp); ok && e.family == .Xml {
			if nerr := engine.apply_xml_arrays(&doc, .Schema, xml_desc, alloc); nerr != nil {
				tape.destroy_document(&doc)
				return query.NULL, nerr, true
			}
		}
	}
	if owns_src { doc.flags += {.Owns_Src} }
	dv, ds := query.document_value(h, doc, owned = true)
	if ds != .Ok {
		if owns_src { doc.flags -= {.Owns_Src} }
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
mod_read_hook :: proc(_: rawptr, path: string, alloc: runtime.Allocator) -> (string, bool) {
	b, ok := read_path_or_stdin(path, false, io.Writer{}, alloc)
	return string(b), ok
}

@(private = "file")
locked_alloc_fn :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_ptr: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	sh := (^Shared_Query_State)(data)
	sync.mutex_guard(&sh.alloc_lock)
	return sh.alloc.procedure(sh.alloc.data, mode, size, alignment, old_ptr, old_size, loc)
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

@(private = "file")
shared_query_init_base :: proc(o: ^Options, cfg: ^Render_Config, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> ^Shared_Query_State {
	sh := new(Shared_Query_State, alloc)
	sh^ = {
		o           = o,
		cfg         = cfg,
		compact_cfg = {compact = true, colors = DEFAULT_COLORS},
		where_mode  = o.where_mode,
		budget      = o.budget,
		osink       = osink,
		stderr_w    = stderr_w,
		alloc       = alloc,
	}
	sh.locked_alloc = alloc if alloc.procedure == runtime.heap_allocator().procedure else runtime.Allocator{procedure = locked_alloc_fn, data = sh}
	sh.free_workers = make([dynamic]^Query_Worker, sh.locked_alloc)
	zone_cache_init(&sh.zones, sh.locked_alloc)
	return sh
}

shared_query_init_jq :: proc(o: ^Options, cfg: ^Render_Config, prog: ^jq.Program, plan: ^jq.Plan, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> (sh: ^Shared_Query_State, err: string) {
	sh = shared_query_init_base(o, cfg, osink, stderr_w, alloc)
	sh.main_prog = prog
	sh.used_globals = jq.used_globals_of(prog, alloc)
	sh.ident_main = jq.is_identity(prog)
	sh.needs_overlay = plan.sources[.Main].facts || (o.has_to && (o.to_name == "xml" || o.to_name == "jsonc" || strings.has_prefix(o.to_name, "toml")))
	sh.collect_each = plan.hints.split.kind == .Collect
	if !o.raw && !o.join && !o.raw0 && !o.sort_keys && !o.ascii && !cfg.color && !o.seq && !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.where_mode && !o.exit_status && !o.skip_bad && o.budget == {} {
		sh.fast_json = .Compact if o.compact else (.Pretty2 if (!o.tab && o.indent == 2) else .None)
	}
	clone_body :: proc(base: ^jq.Program, body: $T, a: runtime.Allocator) -> ^jq.Program {
		p := new_clone(base^, a)
		p.body = body
		return p
	}
	if o.stream {
		if sp, serrs := jq.compile("tostream", {}, alloc); len(serrs) == 0 { sh.stream_prog = sp } else { jq.destroy_program(sp) }
	}
	sp_h := &plan.hints.split
	if ((sp_h.kind == .Stream || sp_h.kind == .Collect) && !sp_h.has_each) || (sp_h.kind == .Collect && (!sp_h.has_tail || plan.tail_body == nil)) {
		if ip, ierrs := jq.compile(".", {}, alloc); len(ierrs) == 0 { sh.ident_prog = ip } else { jq.destroy_program(ip) }
	}
	if (sp_h.kind == .Stream || sp_h.kind == .Collect || (sp_h.kind == .Length && sp_h.has_each)) && (!sp_h.has_each || plan.each_body != nil) {
		if sp_h.has_each { sh.each_prog = clone_body(prog, plan.each_body, alloc) } else if sh.ident_prog != nil { sh.each_prog = new_clone(sh.ident_prog^, alloc) }
	}
	if sp_h.kind == .Collect {
		if sp_h.has_tail && plan.tail_body != nil { sh.tail_prog = clone_body(prog, plan.tail_body, alloc) } else if sh.ident_prog != nil { sh.tail_prog = new_clone(sh.ident_prog^, alloc) }
	}
	if plan.hints.conditional.active && plan.hints.conditional.cmp.op == .None && plan.pred_body != nil {
		sh.pred_prog = clone_body(prog, plan.pred_body, alloc)
	}
	if len(sh.used_globals) == 0 || sh.used_globals[0] {
		if ev, ev_err := os.environ(alloc); ev_err == nil { sh.env_entries = ev }
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
				shared_query_destroy(sh)
				lbl := fmt.aprintf("invalid JSON text passed to --argjson: %s", vs.raw, allocator = alloc)
				defer delete(lbl, alloc)
				return nil, format_arg_parse_err(lbl, raw_b, derr, alloc)
			}
			pv.doc, pv.has_doc = doc, true
		case .Raw_File, .Slurp_File:
			data, rerr := os.read_entire_file_from_path(vs.raw, alloc)
			if rerr != nil {
				sh.vars[i] = pv
				shared_query_destroy(sh)
				flag_s := "--rawfile" if vs.kind == .Raw_File else "--slurpfile"
				return nil, fmt.aprintf("%s %s %s: Could not open %s: %s", flag_s, vs.name, vs.raw, vs.raw, os.error_string(rerr), allocator = alloc)
			}
			pv.raw_text, pv.raw_owned = string(data), true
			if vs.kind == .Slurp_File {
				docs := make([dynamic]tape.Document, alloc)
				it, ok := rec_loop_open(data, engine.spec_of_id(.Json), .Concatenated, {budget = o.budget}, false, vs.raw, io.Writer{}, alloc)
				bad_err: tape.Error = it.open_err if !ok else nil
				bad_src: []u8 = data
				if ok {
					for rec, _, rec_err in rec_loop_next(&it) {
						if rec_err != nil { bad_err, bad_src = rec_err, data; break }
						doc, berr := engine.build(rec, engine.spec_of_id(.Json), {budget = o.budget}, alloc)
						if berr != nil { bad_err, bad_src = berr, rec; break }
						append(&docs, doc)
					}
					if bad_err == nil && it.tail_err != nil { bad_err, bad_src = it.tail_err, data }
					rec_loop_close(&it)
				}
				if bad_err != nil {
					for &d in docs { tape.destroy_document(&d) }
					delete(docs)
					sh.vars[i] = pv
					lbl := fmt.aprintf("parse error in --slurpfile %s", vs.raw, allocator = alloc)
					defer delete(lbl, alloc)
					msg := format_arg_parse_err(lbl, bad_src, bad_err, alloc)
					shared_query_destroy(sh)
					return nil, msg
				}
				pv.slurp_docs = docs[:]
			}
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
				shared_query_destroy(sh)
				lbl := fmt.aprintf("invalid JSON for --jsonargs: %s", ps.raw, allocator = alloc)
				defer delete(lbl, alloc)
				return nil, format_arg_parse_err(lbl, raw_b, derr, alloc)
			}
			pp.doc, pp.has_doc = doc, true
		}
		sh.pos[i] = pp
	}
	return sh, ""
}

shared_query_destroy :: proc(sh: ^Shared_Query_State) {
	if sh == nil { return }
	a := sh.alloc
	for w in sh.free_workers { free_query_worker(w) }
	delete(sh.free_workers)
	if sh.has_aux { engine.destroy_aux_set(&sh.aux_set) }
	for b in sh.aux_srcs { delete(b, a) }
	delete(sh.aux_srcs, a)
	for &pv in sh.vars {
		if pv.has_doc { tape.destroy_document(&pv.doc) }
		for &sd in pv.slurp_docs { tape.destroy_document(&sd) }
		delete(pv.slurp_docs, a)
		if pv.raw_owned { delete(pv.raw_text, a) }
	}
	delete(sh.vars, a)
	for &pp in sh.pos {
		if pp.has_doc { tape.destroy_document(&pp.doc) }
	}
	delete(sh.pos, a)
	for e in sh.env_entries { delete(e, a) }
	delete(sh.env_entries, a)
	if sh.merge.err_msg != "" { delete(sh.merge.err_msg, sh.locked_alloc) }
	if sh.merge.halt_msg != "" { delete(sh.merge.halt_msg, sh.locked_alloc) }
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
load_shared_aux :: proc(sh: ^Shared_Query_State, o: ^Options, plan: ^query.Plan, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	n := len(o.with_sources)
	if n == 0 { return EXIT_OK }
	srcs := make([][]u8, n, alloc)
	aux_list := make([]engine.Aux_Source, n, alloc)
	defer delete(aux_list, alloc)

	for ws, i in o.with_sources {
		data, rok := read_path_or_stdin(ws.path, false, stderr_w, alloc)
		if !rok {
			for k in 0 ..< i { delete(srcs[k], alloc) }
			delete(srcs, alloc)
			return EXIT_USAGE
		}
		srcs[i] = data
		sp, fr := engine.spec_of_id(.Json), engine.Framing.Single
		if ws.has_fmt {
			sp, fr = ws.spec, ws.framing
		} else if fe, ffr, ok := engine.format_of_path(ws.path); ok {
			sp, fr = fe.spec, ffr
		}
		if o.merge_keys && sp == engine.spec_of_id(.Yaml) { sp = engine.spec_of_id(.Yaml_Merge) }
		aux_list[i] = {name = ws.name, src = data, spec = sp, opts = read_opts_of(o, sp, nil), framing = fr}
	}
	sh.aux_srcs = srcs
	aux_set, lres := engine.load_aux_sources(plan, aux_list, alloc)
	if lres.err != .None {
		fail_idx := 0
		for ws, i in o.with_sources {
			if ws.name == lres.failed { fail_idx = i; break }
		}
		fws := o.with_sources[fail_idx]
		if lres.read_err != nil {
			_ = print_tape_error(stderr_w, fws.path, lres.read_err, srcs[fail_idx], aux_list[fail_idx].spec)
		} else if stderr_w.procedure != nil {
			fmt.wprintf(stderr_w, "stury: error: failed to load --with %s=%s\n", fws.name, fws.path)
		}
		return EXIT_RUNTIME
	}
	sh.aux_set, sh.has_aux = aux_set, true
	return EXIT_OK
}

@(private = "file")
global_needed :: #force_inline proc "contextless" (used: []bool, idx: int) -> bool {
	return len(used) == 0 || (idx < len(used) && used[idx])
}

@(private = "file")
find_global_slot :: proc "contextless" (prog: ^jq.Program, target: string) -> int {
	for name, idx in prog.globals {
		if idx >= 2 && name == target { return idx }
	}
	return -1
}

build_globals_from_shared :: proc(h: ^query.Heap, prog: ^jq.Program, sh: ^Shared_Query_State, alloc: runtime.Allocator) -> ([]query.Value, bool) {
	globals := make([]query.Value, len(prog.globals), alloc)
	for &g in globals { g = query.NULL }
	ok := false
	defer if !ok {
		for g in globals { query.release(h, g) }
		delete(globals, alloc)
	}

	if global_needed(sh.used_globals, 0) {
		env_obj, eok := query.make_object(h, len(sh.env_entries))
		if eok != .Ok { return nil, false }
		for entry in sh.env_entries {
			eq := strings.index_byte(entry, '=')
			ks, s1 := query.text_value(h, entry[:eq] if eq >= 0 else entry)
			vs, s2 := query.text_value(h, entry[eq + 1:] if eq >= 0 else "")
			if s1 != .Ok || s2 != .Ok || query.object_put(h, &env_obj, ks, vs) != .Ok {
				if s1 != .Ok || s2 != .Ok { query.release(h, ks); query.release(h, vs) }
				query.release(h, env_obj)
				return nil, false
			}
		}
		globals[0] = env_obj
	}

	args_slot, build_cfg_slot := -1, -1
	need_any_var := false
	for name, idx in prog.globals {
		if !global_needed(sh.used_globals, idx) { continue }
		if name == "ARGS" { args_slot = idx } else if name == "JQ_BUILD_CONFIGURATION" { build_cfg_slot = idx } else if idx >= 2 { need_any_var = true }
	}
	need_prog_args := global_needed(sh.used_globals, 1)

	prog_args, named_obj := query.ABSENT, query.ABSENT
	defer {
		if prog_args.kind != .Absent { query.release(h, prog_args) }
		if named_obj.kind != .Absent { query.release(h, named_obj) }
	}
	if need_prog_args || args_slot >= 0 {
		ps: query.Status
		prog_args, ps = query.make_array(h, len(sh.pos))
		if ps != .Ok { return nil, false }
		for pp in sh.pos {
			v: query.Value; st: query.Status
			if pp.is_json { v, st = query.document_value(h, pp.doc, owned = false) } else { v, st = query.text_value(h, pp.raw_text) }
			if st != .Ok || query.append_owned(h, &prog_args, v) != .Ok { return nil, false }
		}
		if need_prog_args { globals[1] = query.retain(prog_args) }
	}
	if args_slot >= 0 {
		ns: query.Status
		named_obj, ns = query.make_object(h, len(sh.vars))
		if ns != .Ok { return nil, false }
	}
	if need_any_var || args_slot >= 0 {
		for pv in sh.vars {
			slot := find_global_slot(prog, pv.name)
			if slot < 0 || (args_slot < 0 && !global_needed(sh.used_globals, slot)) { continue }
			val: query.Value
			st := query.Status.Ok
			switch pv.kind {
			case .Arg, .Raw_File: val, st = query.text_value(h, pv.raw_text)
			case .Arg_Json:       val, st = query.document_value(h, pv.doc, owned = false)
			case .Slurp_File:
				val, st = query.make_array(h, len(pv.slurp_docs))
				if st == .Ok {
					for sd in pv.slurp_docs {
						dv, dst := query.document_value(h, sd, owned = false)
						if dst != .Ok || query.append_owned(h, &val, dv) != .Ok {
							query.release(h, val)
							st = .Error
							break
						}
					}
				}
			}
			if st != .Ok { return nil, false }
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
			slot := find_global_slot(prog, b.name)
			if slot < 0 || !global_needed(sh.used_globals, slot) { continue }
			val, st := engine.aux_binding_to_value(&b, h)
			if st != .Ok { return nil, false }
			query.release(h, globals[slot])
			globals[slot] = val
		}
	}
	if args_slot >= 0 {
		args_obj, as := query.make_object(h, 2)
		if as != .Ok { return nil, false }
		if k1, s1 := query.text_value(h, "positional"); s1 == .Ok { _ = query.object_put(h, &args_obj, k1, query.retain(prog_args)) }
		if k2, s2 := query.text_value(h, "named"); s2 == .Ok { _ = query.object_put(h, &args_obj, k2, query.retain(named_obj)) }
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
hook_msg :: proc(sh: ^Shared_Query_State, v: query.Value, h: ^query.Heap, is_debug: bool) {
	if sh.stderr_w.procedure == nil { return }
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

new_query_worker :: proc(sh: ^Shared_Query_State, alloc: runtime.Allocator, exclusive: bool) -> (^Query_Worker, bool) {
	w := new(Query_Worker, alloc)
	w^ = {
		shared       = sh,
		scratch      = make([dynamic]u8, 0, 256, alloc),
		where_sb     = strings.builder_make(alloc),
		is_exclusive = exclusive,
		alloc        = alloc,
	}
	query.heap_init(&w.h, alloc, memory_limit = sh.budget.memory, depth = int(sh.budget.depth))
	w.h.keep_origins = sh.where_mode
	if sh.is_jp {
		jsonpath.run_init(&w.jp_run, sh.jp_prog, &w.h, {want_paths = sh.where_mode, budget = sh.budget})
		return w, true
	}
	globs, gok := build_globals_from_shared(&w.h, sh.main_prog, sh, alloc)
	if !gok {
		strings.builder_destroy(&w.where_sb)
		delete(w.scratch)
		query.heap_destroy(&w.h)
		free(w, alloc)
		return nil, false
	}
	w.globals = globs
	w.hook_ctx = {o = sh.o, stderr_w = sh.stderr_w, alloc = alloc}
	w.hooks = {
		data              = w,
		markup            = engine.markup_hook,
		parse_json        = parse_json_for_jq,
		now               = proc(_: rawptr) -> f64 { return f64(time.time_to_unix_nano(time.now())) / 1e9 },
		random            = proc(_: rawptr, b: []u8) { runtime.rand_bytes(b) },
		debug             = proc(d: rawptr, v: query.Value, h: ^query.Heap) { hook_msg((^Query_Worker)(d).shared, v, h, true) },
		stderr            = proc(d: rawptr, v: query.Value, h: ^query.Heap) { hook_msg((^Query_Worker)(d).shared, v, h, false) },
		input             = proc(d: rawptr, h: ^query.Heap) -> (query.Value, bool, query.Status) { return hook_next_input(&(^Query_Worker)(d).hook_ctx, h) },
		input_filename    = proc(d: rawptr, h: ^query.Heap) -> (query.Value, query.Status) { return query.text_value(h, (^Query_Worker)(d).hook_ctx.file_path) },
		input_line_number = proc(d: rawptr) -> i64 { return (^Query_Worker)(d).hook_ctx.line_number },
		zone              = proc(d: rawptr, secs: i64) -> (query.Zone, bool) { return local_zone_at(&(^Query_Worker)(d).shared.zones, secs) },
	}
	jq.run_init(&w.run, sh.main_prog, &w.h, globs, &w.hooks, steps = int(sh.budget.steps))
	if sh.each_prog != nil { jq.run_init(&w.each_run, sh.each_prog, &w.h, globs, &w.hooks, steps = int(sh.budget.steps)); w.has_each_run = true }
	if sh.pred_prog != nil { jq.run_init(&w.pred_run, sh.pred_prog, &w.h, globs, &w.hooks, steps = int(sh.budget.steps)); w.has_pred_run = true }
	return w, true
}

free_query_worker :: proc(w: ^Query_Worker) {
	if w == nil { return }
	a := w.alloc
	if w.shared != nil && w.shared.is_jp {
		jsonpath.run_destroy(&w.jp_run)
	} else {
		hook_ctx_close(&w.hook_ctx)
		if w.has_each_run { jq.run_destroy(&w.each_run) }
		if w.has_pred_run { jq.run_destroy(&w.pred_run) }
		jq.run_destroy(&w.run)
		for g in w.globals { query.release(&w.h, g) }
		delete(w.globals, a)
	}
	delete(w.scratch)
	strings.builder_destroy(&w.where_sb)
	if w.err_msg != "" { delete(w.err_msg, a) }
	if w.halt_msg != "" { delete(w.halt_msg, a) }
	if w.tw != nil {
		ta := w.tw.allocator if w.tw.allocator.procedure != nil else a
		engine.table_writer_drop(w.tw)
		free(w.tw, ta)
	}
	if w.rtw != nil {
		ra := w.rtw.allocator if w.rtw.allocator.procedure != nil else a
		render_table_writer_drop(w.rtw)
		free(w.rtw, ra)
	}
	query.heap_destroy(&w.h)
	free(w, a)
}

@(private = "file")
reset_worker_errs :: proc(w: ^Query_Worker) {
	w.out_count, w.last_falsy, w.has_halt, w.halt_code, w.nul_err = 0, false, false, 0, false
	if w.err_msg != "" { delete(w.err_msg, w.alloc); w.err_msg = "" }
	if w.halt_msg != "" { delete(w.halt_msg, w.alloc); w.halt_msg = "" }
}

@(private = "file")
acquire_worker :: proc(sh: ^Shared_Query_State) -> (^Query_Worker, bool) {
	sync.mutex_lock(&sh.pool_lock)
	if len(sh.free_workers) > 0 {
		w := pop(&sh.free_workers)
		sync.mutex_unlock(&sh.pool_lock)
		return w, true
	}
	sync.mutex_unlock(&sh.pool_lock)
	return new_query_worker(sh, sh.locked_alloc, true)
}

@(private = "file")
release_worker :: proc(sh: ^Shared_Query_State, w: ^Query_Worker) {
	if w == nil { return }
	reset_worker_errs(w)
	w.file_name, w.hook_ctx.file_path, w.tw, w.rtw = "", "", nil, nil
	sync.mutex_guard(&sh.pool_lock)
	append(&sh.free_workers, w)
}

@(private = "file")
worker_hook_init :: proc(pctx: rawptr, _: int, _: runtime.Allocator) -> rawptr {
	p := (^Query_Worker)(pctx)
	if p == nil || p.shared == nil { return nil }
	c, ok := acquire_worker(p.shared)
	if !ok { return nil }
	c.file_name = p.file_name
	return c
}

@(private = "file")
worker_hook_fini :: proc(_: rawptr, _: int, wctx: rawptr) {
	if w := (^Query_Worker)(wctx); w != nil { release_worker(w.shared, w) }
}

@(private = "file")
merge_worker_outcome :: proc(sh: ^Shared_Query_State, w: ^Query_Worker, key: Order_Key, ee: engine.Exec_Error, count_e := true) {
	if ee == .Tainted { return }
	sync.mutex_guard(&sh.merge_lock)
	m := &sh.merge
	if count_e && w.out_count > 0 {
		m.total_emitted += w.out_count
		if !m.has_last || !key_lt(key, m.last_key) {
			m.has_last, m.last_key, m.last_falsy = true, key, w.last_falsy
		}
	}
	if w.nul_err { m.nul_err = true }
	if ee != .None && ee != .Stopped && (!m.has_err || key_lt(key, m.err_key)) {
		m.has_err, m.err_key, m.err_kind = true, key, ee
		if m.err_msg != "" { delete(m.err_msg, sh.locked_alloc); m.err_msg = "" }
		if w.err_msg != "" { m.err_msg = strings.clone(w.err_msg, sh.locked_alloc) }
		if m.halt_msg != "" { delete(m.halt_msg, sh.locked_alloc); m.halt_msg = "" }
		if w.halt_msg != "" { m.halt_msg = strings.clone(w.halt_msg, sh.locked_alloc) }
		if w.has_halt { m.halt_code = w.halt_code }
	}
}

@(private = "file")
build_where_prefix :: proc(sb: ^strings.Builder, h: ^query.Heap, v: query.Value, file, norm_path: string) -> []u8 {
	strings.builder_reset(sb)
	if pl, pok := query.value_place(h, v); pok { where_prefix(sb, file, pl) }
	if norm_path != "" { fmt.sbprintf(sb, "%s ", norm_path) }
	return transmute([]u8)strings.to_string(sb^)
}

format_halt_text :: proc(h: ^query.Heap, hs: jq.Halt_State, alloc: runtime.Allocator) -> string {
	if hs.value.kind == .Absent || hs.value.kind == .Null { return "" }
	buf := make([dynamic]u8, 0, 64, alloc)
	defer delete(buf)
	if query.type_of(hs.value) == .String {
		append(&buf, query.text_of(hs.value))
	} else {
		_ = query.write_json(h, &buf, hs.value, {double = jq_double, too_deep = TOO_DEEP_TEXT})
	}
	append(&buf, '\n')
	return strings.clone(string(buf[:]), alloc)
}

format_halt_message :: proc(w: ^Query_Worker, hs: jq.Halt_State) {
	msg := format_halt_text(&w.h, hs, w.alloc)
	if msg == "" { return }
	if w.halt_msg != "" { delete(w.halt_msg, w.alloc) }
	w.halt_msg = msg
}

// Unified value emitter shared by both jq and JSONPath evaluation callbacks.
@(private = "file")
emit_rendered_value :: proc(
	w: ^Query_Worker,
	v: query.Value,
	meta: engine.Record_Meta,
	emit: engine.Emitter,
	cfg: ^Render_Config,
	norm_path := "",
	allow_tabular := true,
) -> engine.Exec_Error {
	sh := w.shared
	if allow_tabular && cfg.to_tabular {
		if w.tw == nil {
			if sh == nil || w != sh.serial_worker || w.alloc.procedure == nil {
				w.err_msg = strings.clone("tabular output requires serial execution", w.alloc)
				return .Write_Error
			}
			no_hdr := sh.direct_tab_active && sh.osink.total_written > sh.direct_tab_bytes
			if !ensure_tab_writer(sh.o, cfg, w, sh.osink, w.alloc, force_no_header = no_hdr) {
				w.err_msg = strings.clone("cannot start tabular writer", w.alloc)
				return .Write_Error
			}
		}
		if !write_table_row(&w.h, v, w.tw) {
			err := w.tw.err if w.tw.err != nil else engine.Write_Error(engine.Write_Refused{why = .Not_A_Table})
			if ioe, is_io := err.(io.Error); is_io {
				sh.osink.failed, sh.osink.io_err = true, ioe
				return .Stopped
			}
			w.err_msg = write_error_string(err, w.alloc)
			return .Write_Error
		}
		return .None
	}
	if allow_tabular && cfg.to_render != .None {
		if w.rtw == nil {
			if sh == nil || w != sh.serial_worker || w.alloc.procedure == nil {
				w.err_msg = strings.clone("table/markdown output requires serial execution", w.alloc)
				return .Write_Error
			}
			if !ensure_render_writer(sh.o, cfg, w, sh.osink, w.alloc) {
				w.err_msg = strings.clone("cannot start table renderer", w.alloc)
				return .Write_Error
			}
		}
		if !render_table_writer_value(w.rtw, &w.h, v) {
			if w.h.tainted { return .Tainted }
			err := w.rtw.err if w.rtw.err != nil else engine.Write_Error(engine.Write_Refused{why = .No_Spelling})
			if ioe, is_io := err.(io.Error); is_io {
				sh.osink.failed, sh.osink.io_err = true, ioe
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
		ew := Emit_Writer{emit = emit}
		ok, emsg := write_value_as_format(&w.h, v, cfg.to_spec, cfg.write_opts, &w.scratch, emit_writer_io(&ew), int(sh.budget.depth), w.alloc)
		if !ok {
			if w.h.tainted { return .Tainted }
			if ew.stopped { return .Stopped }
			w.err_msg = emsg
			return .Write_Error
		}
		e, _ := engine.entry_of_spec(cfg.to_spec)
		if !e.binary && (!ew.wrote_any || ew.last_byte != '\n') {
			nl := [1]u8{'\n'}
			if _, werr := io.write(emit_writer_io(&ew), nl[:]); werr != .None { return .Stopped }
		}
		if !emit_writer_flush(&ew) { return .Stopped }
		if cfg.one_doc { _ = sync.atomic_add(&cfg.docs_emitted, 1) }
		return .None
	}
	prefix: []u8
	if sh.where_mode && allow_tabular {
		prefix = build_where_prefix(&w.where_sb, &w.h, v, meta.file_path if meta.file_path != "" else w.file_name, norm_path)
	}
	st, stopped := render_value_to_emitter(&w.h, v, cfg, prefix, &w.scratch, emit, emit.fn == out_sink_emit, &w.nul_err)
	if stopped { return .Stopped }
	if st != .Ok {
		if w.h.tainted { return .Tainted }
		if w.nul_err {
			w.err_msg = strings.clone("Cannot dump a string containing NUL with --raw-output0 option", w.alloc)
			return .Failed
		}
		if !sh.is_jp {
			e := query.take_error(&w.h)
			w.err_msg = jq.error_message(&w.h, &e, w.alloc)
			query.destroy_error(&w.h, &e)
		}
		return .Failed
	}
	return .None
}

@(private = "file")
finish_jq_end :: proc(w: ^Query_Worker, run_ptr: ^jq.Run, end: jq.Run_End) -> engine.Exec_Error {
	if w.h.tainted || end == .Tainted { return .Tainted }
	switch end {
	case .Done:    return .None
	case .Stopped: return .Stopped
	case .Tainted: return .Tainted
	case .Halted:
		hs := jq.run_halt(run_ptr)
		w.has_halt, w.halt_code = true, hs.code
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
run_prog_on_value :: proc(w: ^Query_Worker, run_ptr: ^jq.Run, inp: query.Value, meta: engine.Record_Meta, emit: engine.Emitter, cfg: ^Render_Config, allow_tabular: bool) -> engine.Exec_Error {
	reset_worker_errs(w)
	w.jq_bridge = {w = w, meta = meta, emit = emit, cfg = cfg, allow_tabular = allow_tabular}
	defer w.jq_bridge = {}
	end := jq.run_value(run_ptr, inp, proc(d: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		b := (^Jq_Bridge)(d)
		defer query.release(h, v)
		vt := query.type_of(v)
		b.w.out_count += 1
		b.w.last_falsy = (vt == .Null || vt == .False || vt == .Absent)
		if err := emit_rendered_value(b.w, v, b.meta, b.emit, b.cfg, "", b.allow_tabular); err != .None {
			b.err = err
			return false
		}
		return true
	}, &w.jq_bridge)
	if w.jq_bridge.err != .None { return w.jq_bridge.err }
	return finish_jq_end(w, run_ptr, end)
}

@(private = "file")
prepare_worker_doc :: proc(w: ^Query_Worker, doc: ^tape.Document, meta: engine.Record_Meta, keep_origins: bool) -> (cur_w: ^Query_Worker, acquired: bool, err: engine.Exec_Error) {
	sh := w.shared
	cur_w = w
	if !w.is_exclusive {
		cw, ok := acquire_worker(sh)
		if !ok { return nil, false, .No_Memory }
		cw.file_name = meta.file_path if meta.file_path != "" else w.file_name
		cur_w, acquired = cw, true
	}
	cur_w.hook_ctx.file_path = meta.file_path if meta.file_path != "" else cur_w.file_name
	cur_w.hook_ctx.line_number = i64(meta.record_index) + 1
	cur_w.h.keep_origins = keep_origins
	cur_w.h.tainted = false
	query.clear_error(&cur_w.h)
	reset_worker_errs(cur_w)
	if doc != nil && len(doc.nodes) > 0 && sh.o.xml_arrays == .Schema && sh.xml_schema_desc != nil && doc.format != nil && doc.format.options == .Xml {
		if nerr := engine.apply_xml_arrays(doc, .Schema, sh.xml_schema_desc, cur_w.alloc); nerr != nil {
			cur_w.err_msg = strings.clone("XML array normalization failed", cur_w.alloc)
			return cur_w, acquired, .Failed
		}
	}
	return cur_w, acquired, .None
}

@(private = "file")
finish_direct_tab_if_active :: proc(sh: ^Shared_Query_State, cur_w: ^Query_Worker, was_unwritten: bool, ee: ^engine.Exec_Error) {
	if sh.direct_tab_active && cur_w == sh.serial_worker && cur_w.tw != nil {
		tcode := finish_tab_writer(cur_w.tw, sh.osink, sh.stderr_w, cur_w.alloc)
		cur_w.tw = nil
		if tcode != EXIT_OK && (ee^ == .None || ee^ == .Stopped) {
			ee^ = .Stopped if sh.osink.failed else .Write_Error
		} else if was_unwritten && sh.osink.total_written > sh.direct_tab_bytes && !sh.o.dsv_out.no_header {
			sh.direct_tab.suppress_next_hdr = true
		}
	}
}

@(private = "file")
eval_jq_with :: proc(w: ^Query_Worker, use_each: bool, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	sh := w.shared
	cur_w, acquired, perr := prepare_worker_doc(w, doc, meta, sh.where_mode)
	if cur_w == nil { return perr }
	defer if acquired { release_worker(sh, cur_w) }

	count_e := !(use_each && sh.collect_each)
	if perr != .None {
		merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, perr, count_e)
		return perr
	}
	run_ptr := &cur_w.each_run if (use_each && cur_w.has_each_run) else &cur_w.run
	cfg := &sh.compact_cfg if (use_each && sh.collect_each) else sh.cfg
	was_unwritten := sh.direct_tab_active && cur_w == sh.serial_worker && sh.osink.total_written == sh.direct_tab_bytes

	ee: engine.Exec_Error
	if len(doc.nodes) == 0 {
		ee = run_prog_on_value(cur_w, run_ptr, query.NULL, meta, emit, cfg, count_e)
	} else if !use_each && sh.needs_overlay && doc.partial == nil {
		inp, _, ost := query.overlay_from_doc(&cur_w.h, doc^, doc_owned = false)
		if ost != .Ok { return .Failed }
		_ = query.retain(inp)
		ee = run_prog_on_value(cur_w, run_ptr, inp, meta, emit, cfg, count_e)
		query.release(&cur_w.h, inp)
		cur_w.h.write_fact, cur_w.h.write_fact_data = nil, nil
	} else {
		inp, st := query.document_value(&cur_w.h, doc^, owned = false)
		if st != .Ok { return .Failed }
		ee = run_prog_on_value(cur_w, run_ptr, inp, meta, emit, cfg, count_e)
	}
	finish_direct_tab_if_active(sh, cur_w, was_unwritten, &ee)
	if !((ee == .None || ee == .Stopped) && !sh.o.exit_status && !cur_w.nul_err) {
		merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, ee, count_e)
	}
	return ee
}

@(private = "file")
eval_jq_doc :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	w := (^Query_Worker)(ctx)
	return eval_jq_with(w, false, doc, meta, emit) if w != nil else .No_Memory
}

@(private = "file")
eval_jq_each :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	w := (^Query_Worker)(ctx)
	return eval_jq_with(w, true, doc, meta, emit) if w != nil else .No_Memory
}

@(private = "file")
eval_jp_doc :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	w := (^Query_Worker)(ctx)
	if w == nil { return .No_Memory }
	sh := w.shared
	cur_w, acquired, perr := prepare_worker_doc(w, doc, meta, sh.where_mode)
	if cur_w == nil { return perr }
	defer if acquired { release_worker(sh, cur_w) }
	if perr != .None {
		merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, perr, true)
		return perr
	}
	inp, st := query.document_value(&cur_w.h, doc^, owned = false)
	if st != .Ok { return .Failed }
	defer query.release(&cur_w.h, inp)

	was_unwritten := sh.direct_tab_active && cur_w == sh.serial_worker && sh.osink.total_written == sh.direct_tab_bytes
	cur_w.jp_bridge = {w = cur_w, meta = meta, emit = emit}
	defer cur_w.jp_bridge = {}
	end := jsonpath.run_value(&cur_w.jp_run, inp, proc(d: rawptr, val: query.Value, norm_path: string) -> bool {
		b := (^Jp_Bridge)(d)
		defer query.release(&b.w.h, val)
		vt := query.type_of(val)
		b.w.out_count += 1
		b.w.last_falsy = (vt == .Null || vt == .False || vt == .Absent)
		if err := emit_rendered_value(b.w, val, b.meta, b.emit, b.w.shared.cfg, norm_path, true); err != .None {
			b.err = err
			return false
		}
		return true
	}, &cur_w.jp_bridge)
	ret := cur_w.jp_bridge.err
	if ret == .None {
		switch end {
		case .Done:
		case .Stopped:          ret = .Stopped
		case .Tainted:          ret = .Tainted
		case .Exceeded, .Failed: ret = .Failed
		}
	}
	finish_direct_tab_if_active(sh, cur_w, was_unwritten, &ret)
	merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, ret, true)
	return ret
}

@(private = "file")
eval_jq_each_count :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (count: u64, err: engine.Exec_Error) {
	w := (^Query_Worker)(ctx)
	if w == nil { return 0, .No_Memory }
	sh := w.shared
	cur_w, acquired, perr := prepare_worker_doc(w, doc, meta, sh.where_mode)
	if cur_w == nil { return 0, perr }
	defer if acquired { release_worker(sh, cur_w) }
	if perr != .None {
		merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, perr, false)
		return 0, perr
	}
	inp := query.NULL
	if len(doc.nodes) > 0 {
		st: query.Status
		inp, st = query.document_value(&cur_w.h, doc^, owned = false)
		if st != .Ok { return 0, .Failed }
	}
	run_ptr := &cur_w.each_run if cur_w.has_each_run else &cur_w.run
	cnt, end := jq.run_count(run_ptr, inp)
	ee := finish_jq_end(cur_w, run_ptr, end)
	if ee != .None {
		merge_worker_outcome(sh, cur_w, {file_idx = meta.file_index, rec_idx = meta.record_index}, ee, false)
		return 0, ee
	}
	return cnt, .None
}

@(private = "file")
emit_jq_spine_length :: proc(ctx: rawptr, total: u64, emit: engine.Emitter) -> engine.Exec_Error {
	pw := (^Query_Worker)(ctx)
	if pw == nil || pw.shared == nil { return .No_Memory }
	sh := pw.shared
	cur_w, acquired, perr := prepare_worker_doc(pw, nil, {file_path = pw.file_name}, sh.where_mode)
	if cur_w == nil { return perr }
	defer if acquired { release_worker(sh, cur_w) }
	cur_w.out_count = 1
	val := query.int_value(i64(total)) if total <= u64(max(i64)) else query.double_value(f64(total))
	ee := emit_rendered_value(cur_w, val, {file_path = pw.file_name}, emit, sh.cfg)
	if !((ee == .None || ee == .Stopped) && !sh.o.exit_status && !cur_w.nul_err) {
		merge_worker_outcome(sh, cur_w, {file_idx = max(int), rec_idx = max(u64)}, ee, true)
	}
	return ee
}

@(private = "file")
eval_jq_pred :: proc(ctx: rawptr, doc: ^tape.Document, meta: engine.Record_Meta) -> (matched: bool, err: engine.Exec_Error) {
	sh := (^Shared_Query_State)(ctx)
	if sh == nil || sh.pred_prog == nil { return false, .Unsupported }
	w, ok := acquire_worker(sh)
	if !ok { return false, .No_Memory }
	defer release_worker(sh, w)
	_, _, perr := prepare_worker_doc(w, doc, meta, false)
	if perr != .None {
		merge_worker_outcome(sh, w, {file_idx = meta.file_index, rec_idx = meta.record_index}, perr, false)
		return false, perr
	}
	inp, st := query.document_value(&w.h, doc^, owned = false)
	if st != .Ok { return false, .Failed }
	Pred_State :: struct { matched: bool }
	ps := Pred_State{}
	end := jq.run_value(&w.pred_run, inp, proc(d: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		p := (^Pred_State)(d)
		defer query.release(h, v)
		vt := query.type_of(v)
		if vt != .Null && vt != .False && vt != .Absent { p.matched = true }
		return !p.matched
	}, &ps)
	ee := finish_jq_end(w, &w.pred_run, end)
	if ee == .None || ee == .Stopped { return ps.matched, .None }
	merge_worker_outcome(sh, w, {file_idx = meta.file_index, rec_idx = meta.record_index}, ee, false)
	return false, ee
}

@(private = "file")
eval_spine_collect :: proc(ctx: rawptr, _: ^tape.Document, item_outputs: [][]u8, emit: engine.Emitter) -> engine.Exec_Error {
	pw := (^Query_Worker)(ctx)
	if pw == nil || pw.shared == nil || pw.shared.tail_prog == nil { return .Failed }
	sh := pw.shared
	ab := strings.builder_make(sh.locked_alloc)
	defer strings.builder_destroy(&ab)
	strings.write_byte(&ab, '[')
	for item, idx in item_outputs {
		if idx > 0 { strings.write_byte(&ab, ',') }
		strings.write_bytes(&ab, item)
	}
	strings.write_byte(&ab, ']')
	adoc, berr := engine.build(transmute([]u8)strings.to_string(ab), engine.spec_of_id(.Json), {budget = sh.budget}, sh.locked_alloc)
	if berr != nil { return .Read_Error }
	defer tape.destroy_document(&adoc)

	w, ok := acquire_worker(sh)
	if !ok { return .No_Memory }
	defer { w.tw, w.rtw = nil, nil; release_worker(sh, w) }
	w.file_name, w.hook_ctx.file_path = pw.file_name, pw.file_name
	w.h.keep_origins, w.h.tainted = sh.where_mode, false
	query.clear_error(&w.h)
	w.tw, w.rtw = pw.tw, pw.rtw

	tail_run: jq.Run
	jq.run_init(&tail_run, sh.tail_prog, &w.h, w.globals, &w.hooks, steps = int(sh.budget.steps))
	defer jq.run_destroy(&tail_run)
	inp, st := query.document_value(&w.h, adoc, owned = false)
	if st != .Ok { return .Failed }
	ee := run_prog_on_value(w, &tail_run, inp, {file_path = pw.file_name}, emit, sh.cfg, true)
	merge_worker_outcome(sh, w, {file_idx = max(int), rec_idx = max(u64)}, ee, true)
	return ee
}

// ---- `input` / `inputs` Hook Cursor ----

@(private = "file")
hook_ctx_close_file :: proc(hc: ^Hook_Ctx) {
	if hc.recs_open { rec_loop_close(&hc.rec_loop); hc.recs_open = false }
	if hc.stream_open { byte_stream_close(&hc.raw_stream); hc.stream_open = false }
	if hc.dsv_header != nil { delete(hc.dsv_header, hc.alloc); hc.dsv_header = nil }
	if hc.file_buf_owned && hc.file_buf != nil { delete(hc.file_buf, hc.alloc) }
	hc.file_buf, hc.file_buf_owned, hc.single_done = nil, false, false
}

@(private = "file")
hook_ctx_close :: proc(hc: ^Hook_Ctx) {
	hook_ctx_close_file(hc)
	if hc.stream_heap != nil {
		for i := hc.stream_idx; i < len(hc.stream_events); i += 1 { query.release(hc.stream_heap, hc.stream_events[i]) }
	}
	delete(hc.stream_events)
	hc.stream_events, hc.stream_idx, hc.stream_heap = nil, 0, nil
}

@(private = "file")
make_stream_err_val :: proc(h: ^query.Heap, err: tape.Error, src: []u8, fmt_ptr: ^tape.Format) -> (query.Value, bool) {
	if h == nil { return query.NULL, false }
	buf: [256]u8
	arr, st := query.make_array(h, 2)
	if st != .Ok { return query.NULL, false }
	s, s1 := query.text_value(h, tape.error_message(buf[:], err, src, fmt_ptr))
	empty, s2 := query.make_array(h, 0)
	if s1 != .Ok || s2 != .Ok {
		query.release(h, s); query.release(h, empty); query.release(h, arr)
		return query.NULL, false
	}
	_ = query.append_owned(h, &arr, s)
	_ = query.append_owned(h, &arr, empty)
	return arr, true
}

@(private = "file")
hook_enqueue_stream_err :: proc(hc: ^Hook_Ctx, h: ^query.Heap, err: tape.Error, src: []u8, fmt_ptr: ^tape.Format) {
	if arr, ok := make_stream_err_val(h, err, src, fmt_ptr); ok {
		if hc.stream_events.allocator.procedure == nil { hc.stream_events.allocator = hc.alloc }
		append(&hc.stream_events, arr)
		hc.stream_heap = h
	}
}

@(private = "file")
hook_enqueue_stream_doc :: proc(hc: ^Hook_Ctx, h: ^query.Heap, dv: query.Value) -> bool {
	if hc.stream_prog == nil { query.release(h, dv); return false }
	if hc.stream_events.allocator.procedure == nil { hc.stream_events.allocator = hc.alloc }
	hc.stream_heap = h
	srun: jq.Run
	jq.run_init(&srun, hc.stream_prog, h, nil)
	defer jq.run_destroy(&srun)
	return jq.run_value(&srun, dv, proc(d: rawptr, v: query.Value, _: ^query.Heap) -> bool {
		append(&(^Hook_Ctx)(d).stream_events, v)
		return true
	}, hc) == .Done
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
			if !ok { hc.has_open_err = true; continue }
			hc.raw_stream, hc.stream_open, hc.file_path, hc.line_number, hc.cur_spec, hc.cur_framing = bs, true, disp, 0, sp, fr
			return true
		}
		buf, owned, ok := read_input_bytes(p, hc.stdin_override, hc.stderr_w, hc.alloc)
		if !ok { hc.has_open_err = true; continue }
		hc.file_buf, hc.file_buf_owned, hc.file_path, hc.line_number, hc.cur_spec, hc.cur_framing, hc.cur_tabular, hc.single_done = buf, owned, disp, 0, sp, fr, e.tabular, false
		if e.id == .Json && fr == .Single { fr, hc.cur_framing = .Concatenated, .Concatenated }
		if _, framed := engine.to_tape_framing(fr); framed {
			serr_mode := hc.o.stream && hc.o.stream_errors
			it, iok := rec_loop_open(buf, sp, fr, read_opts_of(hc.o, sp, hc.runner), hc.o.skip_bad || (fr == .Seq && !serr_mode), disp, io.Writer{} if serr_mode else hc.stderr_w, hc.alloc)
			if !iok {
				if serr_mode { hook_enqueue_stream_err(hc, hc.stream_heap, it.open_err, buf, e.format); hook_ctx_close_file(hc); return true }
				hook_ctx_close_file(hc)
				return false
			}
			hc.rec_loop, hc.recs_open = it, true
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
			if hc.stream_idx >= len(hc.stream_events) { clear(&hc.stream_events); hc.stream_idx = 0 }
			return ev, true, .Ok
		}
		if hc.raw_lines {
			if !hc.stream_open && !hook_open_next_file(hc) { return query.ABSENT, false, .Ok }
			line: string
			has, had_nl, err := byte_stream_next_raw_line(&hc.raw_stream, &line)
			if err != nil { hook_ctx_close_file(hc); return query.NULL, true, .Error }
			if !has { hook_ctx_close_file(hc); continue }
			if had_nl { hc.line_number += 1 }
			v, st := query.text_value(h, line)
			return v, true, st
		}
		if !hc.recs_open && hc.single_done { hook_ctx_close_file(hc) }
		if hc.file_buf == nil && !hc.recs_open {
			hc.stream_heap = h
			if !hook_open_next_file(hc) { return query.ABSENT, false, .Ok }
			if hc.stream_idx < len(hc.stream_events) { continue }
		}

		dv: query.Value
		if hc.recs_open {
			rec, rinfo, rerr, has := rec_loop_next(&hc.rec_loop)
			if !has {
				tail_err := hc.rec_loop.tail_err
				if tail_err != nil && serr_mode {
					re, _ := engine.entry_of_spec(hc.cur_spec)
					hook_enqueue_stream_err(hc, h, tail_err, hc.file_buf, re.format)
				}
				hook_ctx_close_file(hc)
				if tail_err != nil && !serr_mode { return query.NULL, true, .Error }
				continue
			}
			if rerr != nil {
				if serr_mode {
					re, _ := engine.entry_of_spec(hc.cur_spec)
					hook_enqueue_stream_err(hc, h, rerr, hc.file_buf, re.format)
					continue
				}
				ignoring := hc.o.skip_bad || hc.cur_framing == .Seq
				_ = print_tape_error(hc.stderr_w, hc.file_path, rerr, hc.file_buf, hc.cur_spec, ignoring)
				if ignoring { continue }
				hook_ctx_close_file(hc)
				return query.NULL, true, .Error
			}
			ro := read_opts_of(hc.o, hc.cur_spec, nil)
			buf_copy: []u8
			if hc.cur_tabular {
				buf_copy = make([]u8, len(hc.dsv_header) + len(rec), hc.alloc)
				copy(buf_copy, hc.dsv_header)
				copy(buf_copy[len(hc.dsv_header):], rec)
			} else {
				buf_copy = slice.clone(rec, hc.alloc)
			}
			v, berr, mem_ok := build_doc_val(h, buf_copy, hc.cur_spec, ro, hc.alloc, owns_src = true, xml_arrays = hc.o.xml_arrays, xml_desc = hc.xml_schema_desc)
			if berr != nil || !mem_ok {
				delete(buf_copy, hc.alloc)
				if berr != nil && serr_mode {
					re, _ := engine.entry_of_spec(hc.cur_spec)
					hook_enqueue_stream_err(hc, h, berr, rec, re.format)
					continue
				}
				if berr != nil {
					if hc.cur_tabular {
						adj_err, hdr_len, use_row := berr, u64(len(hc.dsv_header)), true
						if f, is_f := adj_err.(tape.Fault); is_f && f.at != tape.NO_BYTE {
							if f.at >= hdr_len { f.at -= hdr_len; adj_err = f } else { use_row = false }
						} else if ex, is_ex := adj_err.(tape.Exceeded); is_ex && ex.at != tape.NO_BYTE {
							if ex.at >= hdr_len { ex.at -= hdr_len; adj_err = ex } else { use_row = false }
						}
						_ = print_tape_error(hc.stderr_w, hc.file_path, adj_err if use_row else berr, rec if use_row else hc.dsv_header, hc.cur_spec, false, hc.file_buf, rinfo.lo if use_row else 0)
					} else {
						_ = print_tape_error(hc.stderr_w, hc.file_path, berr, rec, hc.cur_spec, false, hc.file_buf, rinfo.lo)
					}
				}
				hook_ctx_close_file(hc)
				return query.NULL, true, .Error
			}
			if hc.cur_tabular {
				c, cs := query.cursor_open(h, v)
				if cs != .Ok { query.release(h, v); hook_ctx_close_file(hc); return query.NULL, true, .Error }
				k, elem, more, ns := query.cursor_next(h, &c)
				query.cursor_close(&c)
				query.release(h, k)
				query.release(h, v)
				if ns != .Ok || !more { query.release(h, elem); hook_ctx_close_file(hc); return query.NULL, true, .Error }
				dv = elem
			} else {
				dv = v
			}
		} else {
			src_copy := slice.clone(hc.file_buf, hc.alloc)
			v, berr, mem_ok := build_doc_val(h, src_copy, hc.cur_spec, read_opts_of(hc.o, hc.cur_spec, hc.runner), hc.alloc, owns_src = true, xml_arrays = hc.o.xml_arrays, xml_desc = hc.xml_schema_desc)
			hc.single_done = true
			if berr != nil || !mem_ok {
				delete(src_copy, hc.alloc)
				if berr != nil && serr_mode {
					re, _ := engine.entry_of_spec(hc.cur_spec)
					hook_enqueue_stream_err(hc, h, berr, hc.file_buf, re.format)
					hook_ctx_close_file(hc)
					continue
				}
				if berr != nil { _ = print_tape_error(hc.stderr_w, hc.file_path, berr, hc.file_buf, hc.cur_spec) }
				hook_ctx_close_file(hc)
				return query.NULL, true, .Error
			}
			dv = v
		}
		hc.line_number += 1
		if hc.o.stream && hc.stream_prog != nil {
			if !hook_enqueue_stream_doc(hc, h, dv) { hook_ctx_close_file(hc); return query.NULL, true, .Error }
			continue
		}
		return dv, true, .Ok
	}
}

// ---- Compilation, Routing & Writer Setup ----

compile_jq_cmd :: proc(o: ^Options, exe_dir, origin_dir, home_dir: string, stderr_w: io.Writer, alloc: runtime.Allocator) -> (prog: ^jq.Program, eff_origin: string, ok: bool, code: int) {
	ft, has_f := o.filter.?
	filter_text, filter_owned := ft if has_f else ".", false
	eff_origin = origin_dir
	if has_f && o.from_file {
		fb, rok := read_path_or_stdin(ft, false, stderr_w, alloc)
		if !rok { return nil, origin_dir, false, EXIT_USAGE }
		if bytes.index_byte(fb, 0) >= 0 {
			delete(fb, alloc)
			if stderr_w.procedure != nil { fmt.wprintln(stderr_w, "stury: error: program file contains NUL bytes") }
			return nil, origin_dir, false, EXIT_USAGE
		}
		filter_text, filter_owned = string(fb), true
		eff_origin = filepath.dir(ft)
		if eff_origin == "" { eff_origin = "." }
	}
	defer if filter_owned { delete(filter_text, alloc) }

	var_names := make([dynamic]string, 0, len(o.vars) + len(o.with_sources) + 2, alloc)
	defer delete(var_names)
	append(&var_names, "ARGS", "JQ_BUILD_CONFIGURATION")
	for vs in o.vars { if !slice.contains(var_names[:], vs.name) { append(&var_names, vs.name) } }
	for ws in o.with_sources { if !slice.contains(var_names[:], ws.name) { append(&var_names, ws.name) } }

	mods := jq.Modules{loader = {read = mod_read_hook, parse_json = parse_json_for_jq}, search = o.lib_dirs[:], origin = eff_origin, jq_origin = exe_dir, home = home_dir}
	with_joins := len(o.with_sources) > 0
	p: ^jq.Program; errs: []jq.Compile_Error
	if with_joins { p, errs = jq.compile_with_joins(filter_text, {variables = var_names[:], modules = mods}, alloc) } else { p, errs = jq.compile(filter_text, {variables = var_names[:], modules = mods}, alloc) }
	if len(errs) > 0 {
		jq.destroy_program(p)
		for e in errs {
			if e.kind == .Located && len(e.src) > 0 {
				esrc, off := transmute([]u8)e.src, u64(max(e.loc.start, 0))
				if with_joins && e.file == "" && len(e.src) == len(filter_text) + len(jq.JOIN_STDLIB) {
					join_len := len(jq.JOIN_STDLIB)
					if ins := strings.index(e.src, jq.JOIN_STDLIB); ins >= 0 && ins <= len(filter_text) && e.src[:ins] == filter_text[:ins] && e.src[ins + join_len:] == filter_text[ins:] {
						raw_off := max(e.loc.start, 0)
						esrc = transmute([]u8)filter_text
						off = u64(raw_off - join_len if raw_off >= ins + join_len else ins if raw_off > ins else raw_off)
					}
				}
				fl := e.file if e.file != "" else (ft if (has_f && o.from_file) else "<top-level>")
				print_located_error(stderr_w, "jq: error", fl, esrc, off, e.msg)
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
can_direct_tabular :: proc "contextless" (o: ^Options, cfg: ^Render_Config, sp: engine.Spec) -> bool {
	e, ok := engine.entry_of_spec(sp)
	return ok && cfg.to_tabular && !o.grow_header && !o.sort_keys && !o.ascii && !o.dsv_out.infer && o.dsv_out.comment == 0 && !o.dsv_out.crlf && o.dsv_out.delimiter == 0 && !o.each && (e.id == .Csv || e.id == .Tsv)
}

@(private = "file")
direct_out_of :: proc "contextless" (sp: engine.Spec) -> engine.Direct_Output {
	e, ok := engine.entry_of_spec(sp)
	return .Csv if (ok && e.id == .Csv) else (.Tsv if (ok && e.id == .Tsv) else .Json)
}

@(private = "file")
projection_direct_blocked :: proc "contextless" (o: ^Options, cfg: ^Render_Config, total_files: int) -> bool {
	if cfg.to_tabular { return !can_direct_tabular(o, cfg, cfg.to_spec) || total_files > 1 }
	return !o.compact || cfg.color || o.raw || o.join || o.raw0 || o.sort_keys || o.ascii || o.exit_status || cfg.to_non_json || cfg.to_render != .None || o.seq || o.where_mode
}

@(private = "file")
fallback_non_direct_route :: proc(dec: ^engine.Decision, o: ^Options, cfg: ^Render_Config, plan: ^query.Plan, runner: ^tape.Runner, input_bytes: int) {
	if dec.framing != .Single {
		rec_par := (dec.framing == .Lines || dec.framing == .Seq) && (dec.entry.family == .Json || dec.entry.family == .Dsv) &&
			runner != nil && runner.threads > 0 && (plan == nil || plan.serial == {}) &&
			!cfg.one_doc && !cfg.to_tabular && cfg.to_render == .None && (input_bytes == 0 || input_bytes >= engine.RECORDS_PARALLEL_FROM)
		dec.kind, dec.parallel = .Records_Parallel if rec_par else .Records_Serial, rec_par
		return
	}
	dec.kind = .Scan if (dec.entry.supports_scan && !o.where_mode) else .Whole
	dec.parallel = false
}

@(private = "file")
route_opts_for :: proc "contextless" (o: ^Options, cfg: ^Render_Config, sp: engine.Spec, runner: ^tape.Runner, file_count, input_bytes: int) -> engine.Route_Options {
	fe, ok := engine.entry_of_spec(sp)
	return {
		runner            = runner,
		where_mode        = o.where_mode,
		force_whole       = o.xml_arrays != .Auto && ok && fe.family == .Xml,
		dups              = o.dups,
		file_count        = file_count,
		input_bytes       = input_bytes,
		allow_rerun_whole = true,
		serial_eval_ctx   = cfg.one_doc || cfg.to_tabular || cfg.to_render != .None,
	}
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
	ropts := route_opts_for(o, cfg, sp, runner, file_count, input_bytes)
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
	if (dec.kind == .Projection_Direct && direct_blocked) ||
	   (dec.kind == .Spine_Parallel && !has_each_cb) ||
	   (dec.kind == .Conditional_Whole && plan != nil && plan.hints.conditional.cmp.op == .None && !has_pred_cb) {
		fallback_non_direct_route(&dec, o, cfg, plan, runner, input_bytes)
	}
	if o.explain { explain_decision(stderr_w, plan, &dec, alloc) }
	return dec, eff_fr
}

@(private = "file")
direct_nl_emit :: proc(d: rawptr, b: []u8) -> bool { return out_stream_bytes_nl((^Out_Stream)(d), b) }

@(private = "file")
direct_tab_nl_emit :: proc(d: rawptr, b: []u8) -> bool {
	dt := (^Direct_Tab_Sink)(d)
	if dt.suppress_next_hdr { dt.suppress_next_hdr = false; return true }
	return out_stream_bytes_nl(dt.osink, b)
}

@(private = "file")
ensure_tab_writer :: proc(o: ^Options, cfg: ^Render_Config, w: ^Query_Worker, osink: ^Out_Stream, alloc: runtime.Allocator, force_no_header := false) -> bool {
	if !cfg.to_tabular || w.tw != nil { return true }
	e, ok := engine.entry_of_spec(o.to_spec)
	if !ok || !e.tabular { return false }
	dopts := o.dsv_out
	if force_no_header { dopts.no_header = true }
	if dopts.delimiter == 0 { dopts.delimiter = '\t' if e.id == .Tsv else ',' }
	tw := new(engine.Write_Table_Writer, alloc)
	cells := engine.Write_Cells.Quoted if e.id == .Csv else (.Escaped if e.id == .Tsv else .Bare)
	if engine.table_writer_start(tw, e.format, cells, dopts, {framing = .Lines, sort_keys = o.sort_keys, grow_header = o.grow_header}, out_stream_writer(osink), alloc) != nil {
		free(tw, alloc)
		return false
	}
	w.tw = tw
	return true
}

@(private = "file")
ensure_render_writer :: proc(o: ^Options, cfg: ^Render_Config, w: ^Query_Worker, osink: ^Out_Stream, alloc: runtime.Allocator) -> bool {
	if cfg.to_render == .None || w.rtw != nil { return true }
	rtw := new(Render_Table_Writer, alloc)
	if !render_table_writer_start(rtw, cfg.to_render, o, out_stream_writer(osink), alloc) {
		free(rtw, alloc)
		return false
	}
	w.rtw = rtw
	return true
}

@(private = "file")
report_writer_end_err :: proc(err: engine.Write_Error, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	if err == nil { return EXIT_OK }
	if ioe, is_io := err.(io.Error); is_io {
		osink.failed, osink.io_err = true, ioe
		return report_stdout_error(stderr_w, ioe)
	}
	msg := write_error_string(err, alloc)
	fmt.wprintf(stderr_w, "stury: error: %s\n", msg)
	delete(msg, alloc)
	return EXIT_RUNTIME
}

@(private = "file")
finish_tab_writer :: proc(tw: ^engine.Write_Table_Writer, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	if tw == nil { return EXIT_OK }
	ta := tw.allocator if tw.allocator.procedure != nil else alloc
	_, err := engine.table_writer_end(tw)
	free(tw, ta)
	return report_writer_end_err(err, osink, stderr_w, alloc)
}

@(private = "file")
finish_query_writers :: proc(w: ^Query_Worker, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator, flush_render := true) -> int {
	code := EXIT_OK
	if w.tw != nil {
		code = finish_tab_writer(w.tw, osink, stderr_w, alloc)
		w.tw = nil
	}
	if w.rtw != nil {
		ra := w.rtw.allocator if w.rtw.allocator.procedure != nil else alloc
		if flush_render {
			rcode := report_writer_end_err(render_table_writer_end(w.rtw), osink, stderr_w, alloc)
			if rcode != EXIT_OK && code == EXIT_OK { code = rcode }
		} else {
			render_table_writer_drop(w.rtw)
		}
		free(w.rtw, ra)
		w.rtw = nil
	}
	return code
}

@(private = "file")
flush_and_teardown :: proc(w: ^Query_Worker, osink: ^Out_Stream, stderr_w: io.Writer, alloc: runtime.Allocator, base_code: int, flush_render: bool) -> int {
	code := base_code
	if tcode := finish_query_writers(w, osink, stderr_w, alloc, flush_render = flush_render); tcode != EXIT_OK && code == EXIT_OK {
		code = tcode
	}
	if osink.failed || !out_stream_flush(osink) {
		return report_out_stream_error(osink, stderr_w)
	}
	return code
}

// ---- Unified Engine Execution Helper (JQ & JSONPath) ----

@(private = "file")
make_exec_opts :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Query_State,
	worker: ^Query_Worker,
	emit: engine.Emitter,
	ro: tape.Options,
	runner: ^tape.Runner,
	bad_cb: engine.Bad_Record_Proc,
	bad_ctx: rawptr,
	skip_active: bool,
	fidx: int,
	disp: string,
) -> engine.Exec_Options {
	if sh.is_jp {
		return {
			eval                 = eval_jp_doc,
			eval_ctx             = worker,
			workers              = {init = worker_hook_init, fini = worker_hook_fini},
			emit                 = emit,
			read                 = ro,
			runner               = runner,
			direct_out           = direct_out_of(o.to_spec),
			direct_csv_header    = !o.dsv_out.no_header,
			eval_ctx_thread_safe = true,
			rerun_whole_on_taint = true,
			file_index           = fidx,
			file_path            = disp,
			allocator            = sh.locked_alloc,
		}
	}
	coalesce := !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.unbuffered && !o.each
	sp_hint := &plan.hints.split if plan != nil else nil
	has_count := sh.each_prog != nil && sp_hint != nil && sp_hint.kind == .Length && sp_hint.has_each
	fast_each := sh.fast_json if (sp_hint != nil && (sp_hint.kind == .Stream || (sp_hint.kind == .Collect && !sp_hint.has_tail)) && !sp_hint.has_each) else .None
	collect_compact := sp_hint != nil && sp_hint.kind == .Collect && !sp_hint.has_tail && sh.collect_each && !o.raw && !o.join && !o.raw0 && !o.sort_keys && !o.ascii && o.compact && !cfg.color && !o.seq && !cfg.to_tabular && !cfg.to_non_json && cfg.to_render == .None && !o.where_mode && !o.exit_status
	return {
		eval                  = eval_jq_doc,
		eval_ctx              = worker,
		eval_each             = eval_jq_each if sh.each_prog != nil else nil,
		eval_each_ctx         = worker if sh.each_prog != nil else nil,
		eval_each_count       = eval_jq_each_count if has_count else nil,
		emit_spine_length     = emit_jq_spine_length if has_count else nil,
		pred_eval             = eval_jq_pred if sh.pred_prog != nil else nil,
		pred_ctx              = sh if sh.pred_prog != nil else nil,
		spine_collect         = eval_spine_collect if sh.tail_prog != nil else nil,
		on_bad_record         = bad_cb if skip_active else nil,
		bad_ctx               = bad_ctx,
		workers               = {init = worker_hook_init, fini = worker_hook_fini},
		emit                  = emit,
		read                  = ro,
		runner                = runner,
		direct_out            = direct_out_of(o.to_spec),
		direct_csv_header     = !o.dsv_out.no_header,
		skip_bad              = skip_active,
		fast_json             = sh.fast_json if sh.ident_main else .None,
		fast_json_each        = fast_each,
		coalesce_emit         = coalesce,
		direct_append_nl      = coalesce && !cfg.to_tabular,
		spine_collect_compact = collect_compact,
		eval_ctx_thread_safe  = true,
		rerun_whole_on_taint  = true,
		file_index            = fidx,
		file_path             = disp,
		allocator             = sh.locked_alloc,
	}
}

@(private = "file")
select_direct_emit :: proc(sh: ^Shared_Query_State, cfg: ^Render_Config, osink: ^Out_Stream, base_emit: engine.Emitter, use_direct: bool) -> engine.Emitter {
	sh.direct_tab = {osink = osink}
	if !use_direct { return base_emit }
	if cfg.to_tabular {
		sh.direct_tab_bytes = osink.total_written
		sh.direct_tab_active = true
		return {fn = direct_tab_nl_emit, data = &sh.direct_tab}
	}
	return {fn = direct_nl_emit, data = osink}
}

@(private = "file")
exec_query_on_bytes :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Query_State,
	worker: ^Query_Worker,
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
	if !sh.is_jp {
		worker.hook_ctx = {o = o, file_path = disp, xml_schema_desc = sh.xml_schema_desc, stderr_w = stderr_w, alloc = sh.locked_alloc}
	}
	dec, eff_fr := decide_file_route(o, cfg, plan, sp, fr, len(b), runner, 1, sh.each_prog != nil, sh.pred_prog != nil, stderr_w, alloc, total_files = total_files)
	if dec.kind == .Projection_Direct && cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed {
		fallback_non_direct_route(&dec, o, cfg, plan, runner, len(b))
	}

	decide_concat_fallback :: proc(o: ^Options, cfg: ^Render_Config, plan: ^query.Plan, sp: engine.Spec, runner: ^tape.Runner, nbytes, total_files: int, worker: ^Query_Worker) -> engine.Decision {
		d := engine.decide(plan, sp, .Concatenated, route_opts_for(o, cfg, sp, runner, 1, nbytes))
		if d.kind == .Projection_Direct && (projection_direct_blocked(o, cfg, total_files) || (cfg.to_tabular && worker.tw != nil && worker.tw.stream.headed)) {
			fallback_non_direct_route(&d, o, cfg, plan, runner, nbytes)
		}
		return d
	}

	can_fallback_concat := eff_fr == .Single && dec.entry.id == .Json
	pin_active := pin != nil && (pin.has_expected || pin.out_path != "")
	pin_applied := false
	if pin_active && !can_fallback_concat {
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK { return {}, pcode }
		pin_applied = true
	} else if pin_active && pin.has_expected && !engine.compare_plan_pin(pin.expected, engine.plan_pin_of(&dec)) {
		cand2 := decide_concat_fallback(o, cfg, plan, sp, runner, len(b), total_files, worker)
		if !engine.compare_plan_pin(pin.expected, engine.plan_pin_of(&cand2)) || engine.validate(b, sp, ro, alloc) == nil {
			if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK { return {}, pcode }
			pin_applied = true
		}
	}

	use_direct := dec.kind == .Projection_Direct
	if use_direct && cfg.to_tabular && worker.tw != nil && total_files == 1 && !worker.tw.stream.headed {
		_ = finish_tab_writer(worker.tw, osink, stderr_w, alloc)
		worker.tw = nil
	}
	if !use_direct && cfg.to_tabular && !ensure_tab_writer(o, cfg, worker, osink, alloc) {
		return {err = .Write_Error}, EXIT_OK
	}

	skip_active := !sh.is_jp && (o.skip_bad || eff_fr == .Seq)
	bad_cb :: proc(ctx: rawptr, bad: tape.Bad_Record) -> bool {
		qc := (^Quarantine_Bad_Ctx)(ctx)
		qc.bad_cnt += 1
		if qc.stderr_w.procedure != nil { _ = print_tape_error(qc.stderr_w, qc.display, bad.err, qc.src, qc.sp, qc.ignoring) }
		if qc.qw != nil && qc.qw.active { _ = quarantine_write_bad(qc.qw, qc.bad_cnt, qc.display, bad.err, bad.text, qc.sp, qc.alloc, qc.src) }
		return qc.skip_active
	}
	if bad_ctx != nil {
		bad_ctx^ = {qw = qw, display = disp, src = b, sp = sp, ignoring = true, skip_active = skip_active, stderr_w = stderr_w, alloc = alloc}
	}
	eff_emit := select_direct_emit(sh, cfg, osink, emit, use_direct)
	eopts := make_exec_opts(o, cfg, plan, sh, worker, eff_emit, ro, runner, bad_cb, bad_ctx, skip_active, fidx, disp)
	res = engine.execute(plan, &dec, b, eopts)
	sh.direct_tab_active, sh.direct_tab.suppress_next_hdr = false, false

	if res.err == .Read_Error && res.emitted == 0 && can_fallback_concat {
		if f, is_f := res.read_err.(tape.Fault); is_f && f.kind == .Bad_Char {
			dec2 := decide_concat_fallback(o, cfg, plan, sp, runner, len(b), total_files, worker)
			if pin_active {
				if pcode := plan_pin_apply(pin, &dec2, stderr_w, alloc); pcode != EXIT_OK { return {}, pcode }
				pin_applied = true
			}
			use_direct2 := dec2.kind == .Projection_Direct
			if !use_direct2 && cfg.to_tabular && !ensure_tab_writer(o, cfg, worker, osink, alloc) {
				return {err = .Write_Error}, EXIT_OK
			}
			eopts2 := eopts
			eopts2.emit = select_direct_emit(sh, cfg, osink, emit, use_direct2)
			res = engine.execute(plan, &dec2, b, eopts2)
			sh.direct_tab_active, sh.direct_tab.suppress_next_hdr = false, false
		}
	}
	if pin_active && !pin_applied {
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK { return {}, pcode }
	}
	return res, EXIT_OK
}

// ---- Streaming Stdin Delimited Fast Path ----

@(private = "file")
stream_stdin_delim :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	worker: ^Query_Worker,
	osink: ^Out_Stream,
	emit: engine.Emitter,
	qw: ^Quarantine_Writer,
	pin: ^Plan_Pin_State,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> (handled, had_bad: bool, exit_code: int) {
	if o.each || o.null_input || o.raw_input || o.slurp || o.stream { return false, false, EXIT_OK }
	sp, fr := detect_file_spec(o, "-")
	e, _ := engine.entry_of_spec(sp)
	if e.id != .Json || (fr != .Lines && fr != .Seq) { return false, false, EXIT_OK }
	if !ensure_tab_writer(o, cfg, worker, osink, alloc) { return true, false, EXIT_RUNTIME }
	bs, ok := byte_stream_open("-", nil, stderr_w, alloc)
	if !ok { return true, false, EXIT_USAGE }
	defer byte_stream_close(&bs)

	if o.explain || o.plan_out != "" || o.plan_file != "" {
		dec := engine.decide(plan, sp, fr, {dups = o.dups, where_mode = o.where_mode})
		dec.kind, dec.active_hint, dec.parallel, dec.demand_mode, dec.primary_why = .Records_Serial, .None, false, .Whole, .Records_Framing
		dec.whys += {.Records_Framing}
		dec.whys -= {.Projection_Direct_Hit, .Conditional_Whole_Hit}
		if o.explain { explain_decision(stderr_w, plan, &dec, alloc) }
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK { return true, false, pcode }
	}

	delim := u8(0x1e) if fr == .Seq else '\n'
	span_buf := make([dynamic]u8, 0, 1024, alloc)
	defer delete(span_buf)
	rec_no, line_base, bad_cnt := i64(0), i64(1), 0
	nl_inc := i64(1 if fr == .Lines else 0)

	for {
		span: []u8
		has, had_delim, rerr := byte_stream_next_delim_span(&bs, delim, &span, &span_buf, fr == .Lines)
		if rerr != nil {
			fmt.wprintf(stderr_w, "stury: error: reading stdin: %s\n", os.error_string(rerr))
			return true, bad_cnt > 0, EXIT_USAGE
		}
		if !has { break }
		rec_no += 1
		if len(bytes.trim_space(span)) == 0 && (fr == .Lines || !had_delim) {
			line_base += count_newlines(span) + nl_inc
			continue
		}
		if fr == .Seq && !had_delim {
			f := tape.Fault{at = 0, kind = .Bad_Char}
			_ = print_tape_error(stderr_w, "<stdin>", f, span, sp, ignoring = true)
			if qw != nil && qw.active { _ = quarantine_write_bad(qw, rec_no, "<stdin>", f, span, sp, alloc) }
			if o.skip_bad { bad_cnt += 1 }
			line_base += count_newlines(span)
			continue
		}
		doc, berr := engine.build(span, sp, {budget = o.budget, dups = o.dups}, alloc)
		if berr != nil {
			_ = print_tape_error(stderr_w, "<stdin>", berr, span, sp, ignoring = (fr == .Seq || o.skip_bad))
			if qw != nil && qw.active { _ = quarantine_write_bad(qw, rec_no, "<stdin>", berr, span, sp, alloc) }
			if o.skip_bad { bad_cnt += 1; line_base += count_newlines(span) + nl_inc; continue }
			if fr == .Seq { line_base += count_newlines(span); continue }
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
				if qw != nil && qw.active { _ = quarantine_write_bad(qw, rec_no, "<stdin>", f, span, sp, alloc) }
				if o.skip_bad { bad_cnt += 1 }
				line_base += count_newlines(span)
				continue
			}
		}
		worker.file_name, worker.hook_ctx.file_path, worker.hook_ctx.line_number = "<stdin>", "<stdin>", line_base
		ee := eval_jq_doc(worker, &doc, {file_index = 0, file_path = "<stdin>", record_index = u64(rec_no - 1), raw_bytes = span}, emit)
		tape.destroy_document(&doc)
		if ee == .Halted { return true, bad_cnt > 0, worker.halt_code }
		if osink.failed { return true, bad_cnt > 0, report_out_stream_error(osink, stderr_w) }
		if ee == .Stopped { return true, bad_cnt > 0, EXIT_OK }
		if ee != .None { return true, bad_cnt > 0, handle_shared_result(o, worker.shared, {err = ee}, "<stdin>", span, sp, stderr_w, alloc) }
		line_base += count_newlines(span) + nl_inc
	}
	return true, bad_cnt > 0, EXIT_OK
}

// ---- Multi-File & Pool Helpers ----

@(private = "file")
ensure_lazy_pool :: proc(base_runner: ^tape.Runner, lazy: ^host.Pool, has_lazy: ^bool, o: ^Options) -> ^tape.Runner {
	if base_runner != nil { return base_runner }
	if !has_lazy^ {
		if host.pool_init(lazy, o.threads) != nil { return nil }
		has_lazy^ = true
	}
	return &lazy.runner
}

@(private = "file")
parallel_min_bytes_of :: #force_inline proc "contextless" (o: ^Options) -> int {
	base := min(engine.RECORDS_PARALLEL_FROM, engine.SPINE_PARALLEL_FROM)
	return max(base, 4 << 20) if (o.threads <= 0 && engine.SPINE_PARALLEL_FROM > 0) else base
}

@(private = "file")
total_regular_bytes_small :: proc(paths: []string, alloc: runtime.Allocator) -> bool {
	total := i64(0)
	for p in paths {
		if p == "-" { return false }
		fi, err := os.stat(p, alloc)
		if err != nil { return false }
		is_reg, sz := fi.type == .Regular, fi.size
		os.file_info_delete(fi, alloc)
		if !is_reg { return false }
		total += sz
		if total > MAX_FILES_PARALLEL_BYTES { return false }
	}
	return true
}

@(private = "file")
find_files_read_error :: proc(o: ^Options, plan: ^query.Plan, finputs: []engine.File_Input, ro: tape.Options, alloc: runtime.Allocator) -> int {
	nop_eval :: proc(_: rawptr, _: ^tape.Document, _: engine.Record_Meta, _: engine.Emitter) -> engine.Exec_Error { return .None }
	for fi, k in finputs {
		f_dec := engine.decide(plan, fi.spec, fi.framing, {where_mode = o.where_mode, dups = o.dups, file_count = 1, input_bytes = len(fi.src)})
		if sub := engine.execute(plan, &f_dec, fi.src, {eval = nop_eval, read = ro, direct_out = direct_out_of(o.to_spec), direct_csv_header = !o.dsv_out.no_header, allocator = alloc}); sub.err == .Read_Error {
			return k
		}
	}
	for fi, k in finputs {
		if _, framed := engine.to_tape_framing(fi.framing); framed {
			it, ok := rec_loop_open(fi.src, fi.spec, fi.framing, ro, false, fi.path, io.Writer{}, alloc)
			if !ok { return k }
			for rec, _, err in rec_loop_next(&it) {
				if err != nil { rec_loop_close(&it); return k }
				doc, berr := engine.build(rec, fi.spec, ro, alloc)
				if berr != nil { rec_loop_close(&it); return k }
				tape.destroy_document(&doc)
			}
			tail_err := it.tail_err
			rec_loop_close(&it)
			if tail_err != nil { return k }
		} else {
			doc, berr := engine.build(fi.src, fi.spec, ro, alloc)
			if berr != nil { return k }
			tape.destroy_document(&doc)
		}
	}
	return 0
}

// ---- Null Input, Each-Files, Special Modes (`-R`, `-s`, `--stream`) ----

@(private = "file")
run_null_input :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Query_State,
	worker: ^Query_Worker,
	osink: ^Out_Stream,
	emit: engine.Emitter,
	pin: ^Plan_Pin_State,
	hook_paths: []string,
	stdin_override: Maybe([]u8),
	runner: ^tape.Runner,
	stderr_w: io.Writer,
	alloc: runtime.Allocator,
) -> (ee: engine.Exec_Error, code: int, open_err: bool, pin_failed: bool) {
	if !ensure_tab_writer(o, cfg, worker, osink, alloc) { return .Write_Error, EXIT_RUNTIME, false, false }
	worker.hook_ctx = {
		o = o, paths = hook_paths, stdin_override = stdin_override, raw_lines = o.raw_input,
		stream_prog = sh.stream_prog, stream_heap = &worker.h, runner = runner,
		xml_schema_desc = sh.xml_schema_desc, stderr_w = stderr_w, alloc = sh.locked_alloc,
	}
	defer { hook_ctx_close(&worker.hook_ctx); worker.hook_ctx.paths = nil }
	if o.explain || o.plan_out != "" || o.plan_file != "" {
		dec := engine.decide(plan, o.from_spec, .Single, {null_input = true, runner = runner, dups = o.dups, where_mode = o.where_mode})
		if o.explain { explain_decision(stderr_w, plan, &dec, alloc) }
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK {
			return .None, pcode, false, true
		}
	}
	worker.file_name = "<null>"
	ee = run_prog_on_value(worker, &worker.run, query.NULL, {file_path = "<null>"}, emit, cfg, true)
	merge_worker_outcome(sh, worker, {}, ee, true)
	return ee, finalize_shared_status(o, sh, osink, stderr_w), worker.hook_ctx.has_open_err, false
}

@(private = "file")
run_jq_each_files :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Query_State,
	worker: ^Query_Worker,
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
	has_open_err, worst := false, EXIT_OK
	runner := ensure_lazy_pool(base_runner, lazy_pool, has_lazy_pool, o) if (parallel_allowed && (base_runner != nil || (o.threads > 1 && (o.explain || o.plan_out != "" || o.plan_file != "")))) else nil

	for p in paths {
		single_path := [1]string{p}
		osink.file_label, osink.open_line = p if show_labels else "", false

		sync.mutex_lock(&sh.merge_lock)
		if sh.merge.err_msg != "" { delete(sh.merge.err_msg, sh.locked_alloc) }
		if sh.merge.halt_msg != "" { delete(sh.merge.halt_msg, sh.locked_alloc) }
		sh.merge = {}
		sync.mutex_unlock(&sh.merge_lock)

		fcode := EXIT_OK
		file_open_err := false
		if o.null_input {
			ee, ncode, oerr, pfail := run_null_input(o, cfg, plan, sh, worker, osink, emit, pin, single_path[:], stdin_override, runner, stderr_w, alloc)
			if pfail {
				_ = finish_query_writers(worker, osink, stderr_w, alloc, flush_render = false)
				return EXIT_USAGE if has_open_err else ncode
			}
			file_open_err = oerr
			if oerr { has_open_err = true }
			fcode = ncode
			if ee == .Halted {
				_ = finish_query_writers(worker, osink, stderr_w, alloc, flush_render = (fcode == EXIT_OK && !oerr))
				return fcode
			}
		} else if o.raw_input || o.slurp || o.stream {
			fcode = run_jq_special(o, cfg, plan, sh, worker, osink, emit, qw, pin, single_path[:], stdin_override, runner, stderr_w, alloc)
			if fcode == EXIT_USAGE { has_open_err = true }
		} else {
			b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
			if !rok {
				has_open_err = true
				_ = finish_query_writers(worker, osink, stderr_w, alloc, flush_render = false)
				continue
			}
			disp := "<stdin>" if p == "-" else p
			sp, fr := detect_file_spec(o, p)
			cur_runner := ensure_lazy_pool(base_runner, lazy_pool, has_lazy_pool, o) if (runner == nil && parallel_allowed && len(b) >= parallel_min_bytes) else runner
			bad_ctx: Quarantine_Bad_Ctx
			res, pcode := exec_query_on_bytes(o, cfg, plan, sh, worker, osink, emit, qw, cur_runner, b, disp, sp, fr, 0, 1, &bad_ctx, pin, stderr_w, alloc)
			if pcode != EXIT_OK {
				if owned { delete(b, alloc) }
				_ = finish_query_writers(worker, osink, stderr_w, alloc, flush_render = false)
				return EXIT_USAGE if has_open_err else pcode
			}
			fcode = handle_shared_result(o, sh, res, disp, b, sp, stderr_w, alloc)
			if owned { delete(b, alloc) }
			if res.err == .Halted {
				_ = finish_query_writers(worker, osink, stderr_w, alloc, flush_render = (fcode == EXIT_OK))
				return fcode
			}
			if res.bad_records > 0 && o.skip_bad && fcode < EXIT_RUNTIME { fcode = EXIT_RUNTIME }
		}

		flush_file := (fcode == EXIT_OK || (o.exit_status && fcode == EXIT_FALSY)) && !file_open_err
		if tcode := finish_query_writers(worker, osink, stderr_w, alloc, flush_render = flush_file); tcode != EXIT_OK && fcode == EXIT_OK {
			fcode = tcode
		}
		worst = max(worst, fcode)
		if osink.failed { return report_out_stream_error(osink, stderr_w) }
	}
	osink.file_label = ""
	return EXIT_USAGE if has_open_err else worst
}

@(private = "file")
emit_stream_err :: proc(w: ^Query_Worker, err: tape.Error, disp: string, src: []u8, fmt_ptr: ^tape.Format, emit: engine.Emitter, cfg: ^Render_Config) {
	if arr, ok := make_stream_err_val(&w.h, err, src, fmt_ptr); ok {
		_ = run_prog_on_value(w, &w.run, arr, {file_path = disp}, emit, cfg, true)
	}
}

@(private = "file")
run_jq_special :: proc(
	o: ^Options,
	cfg: ^Render_Config,
	plan: ^query.Plan,
	sh: ^Shared_Query_State,
	w: ^Query_Worker,
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
	if !ensure_tab_writer(o, cfg, w, osink, alloc) { return EXIT_RUNTIME }
	if o.explain || o.plan_out != "" || o.plan_file != "" {
		sp, fr := detect_file_spec(o, paths[0] if len(paths) > 0 else "-")
		dec := engine.decide(plan, sp, fr, {runner = runner, slurp = o.slurp, raw_input = o.raw_input, dups = o.dups, where_mode = o.where_mode})
		if o.explain { explain_decision(stderr_w, plan, &dec, alloc) }
		if pcode := plan_pin_apply(pin, &dec, stderr_w, alloc); pcode != EXIT_OK { return pcode }
	}
	if o.raw_input {
		has_open_err := false
		if o.slurp {
			sb := strings.builder_make(alloc)
			defer strings.builder_destroy(&sb)
			for p in paths {
				b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
				if !rok { has_open_err = true; continue }
				_, _ = io.write(strings.to_writer(&sb), b)
				if owned { delete(b, alloc) }
			}
			sv, st := query.text_value(&w.h, strings.to_string(sb))
			if st != .Ok { return EXIT_RUNTIME }
			ee := run_prog_on_value(w, &w.run, sv, {file_path = "<stdin>" if (len(paths) == 0 || paths[0] == "-") else paths[0]}, emit, cfg, true)
			merge_worker_outcome(sh, w, {}, ee, true)
			if has_open_err && ee != .Halted { return EXIT_USAGE }
			return finalize_shared_status(o, sh, osink, stderr_w)
		}
		for p, fidx in paths {
			disp := "<stdin>" if p == "-" else p
			bs, ok := byte_stream_open(p, stdin_override, stderr_w, alloc)
			if !ok { has_open_err = true; continue }
			idx, nl_cnt := u64(0), i64(0)
			for {
				line: string
				has, had_nl, err := byte_stream_next_raw_line(&bs, &line)
				if err != nil {
					byte_stream_close(&bs)
					fmt.wprintf(stderr_w, "stury: error: Could not read %s: %s\n", p, os.error_string(err))
					return EXIT_USAGE
				}
				if !has { break }
				if had_nl { nl_cnt += 1 }
				sv, st := query.text_value(&w.h, line)
				if st != .Ok { byte_stream_close(&bs); return EXIT_RUNTIME }
				w.file_name, w.hook_ctx.file_path, w.hook_ctx.line_number = disp, disp, nl_cnt
				ee := run_prog_on_value(w, &w.run, sv, {file_path = disp, record_index = idx}, emit, cfg, true)
				merge_worker_outcome(sh, w, {file_idx = fidx, rec_idx = idx}, ee, true)
				if ee != .None {
					byte_stream_close(&bs)
					if ee == .Halted { return w.halt_code }
					if osink.failed { return report_out_stream_error(osink, stderr_w) }
					return EXIT_OK if ee == .Stopped else finalize_shared_status(o, sh, osink, stderr_w)
				}
				idx += 1
			}
			byte_stream_close(&bs)
		}
		return EXIT_USAGE if has_open_err else finalize_shared_status(o, sh, osink, stderr_w)
	}

	srun: jq.Run
	if o.stream && sh.stream_prog != nil { jq.run_init(&srun, sh.stream_prog, &w.h, nil) }
	defer if o.stream && sh.stream_prog != nil { jq.run_destroy(&srun) }

	arr := query.ABSENT
	if !o.stream {
		as: query.Status
		arr, as = query.make_array(&w.h, 8)
		if as != .Ok { return EXIT_RUNTIME }
	}
	defer if !o.stream && arr.kind != .Absent { query.release(&w.h, arr) }

	serr_mode := o.stream && o.stream_errors
	has_open_err, had_bad := false, false
	for p, fidx in paths {
		b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok { has_open_err = true; continue }
		disp := "<stdin>" if p == "-" else p
		sp, fr := detect_file_spec(o, p)
		e, _ := engine.entry_of_spec(sp)
		ro := read_opts_of(o, sp, nil)

		if !o.stream && (e.tabular || (fr == .Single && e.id != .Json)) {
			dv, berr, dok := build_doc_val(&w.h, b, sp, ro, alloc, owns_src = owned, xml_arrays = o.xml_arrays, xml_desc = sh.xml_schema_desc)
			if berr != nil || !dok {
				code := print_tape_error(stderr_w, disp, berr, b, sp) if berr != nil else EXIT_RUNTIME
				if owned { delete(b, alloc) }
				return code
			}
			if e.tabular && query.type_of(dv) == .Array {
				if c, cs := query.cursor_open(&w.h, dv); cs == .Ok {
					for {
						ck, item, more, ns := query.cursor_next(&w.h, &c)
						if ns != .Ok || !more { break }
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
		it, iok := rec_loop_open(b, sp, eff_fr, ro, o.skip_bad || (eff_fr == .Seq && !serr_mode), disp, io.Writer{} if serr_mode else stderr_w, alloc)
		if !iok {
			if serr_mode { emit_stream_err(w, it.open_err, disp, b, e.format, emit, cfg); if owned { delete(b, alloc) }; continue }
			if owned { delete(b, alloc) }
			return EXIT_RUNTIME
		}

		rec_idx := i64(0)
		for rec, rinfo, rerr in rec_loop_next(&it) {
			rec_idx += 1
			if rerr != nil {
				if serr_mode { had_bad = true; emit_stream_err(w, rerr, disp, b, e.format, emit, cfg); continue }
				if o.skip_bad || eff_fr == .Seq {
					if o.skip_bad { had_bad = true }
					_ = print_tape_error(stderr_w, disp, rerr, b, sp, ignoring = true)
					if qw != nil && qw.active { _ = quarantine_write_bad(qw, rec_idx, disp, rerr, rec, sp, alloc, b) }
					continue
				}
				rec_loop_close(&it)
				code := print_tape_error(stderr_w, disp, rerr, b, sp)
				if owned { delete(b, alloc) }
				return code
			}
			rec_copy := slice.clone(rec, alloc)
			dv, berr, bok := build_doc_val(&w.h, rec_copy, sp, ro, alloc, owns_src = true, xml_arrays = o.xml_arrays, xml_desc = sh.xml_schema_desc)
			if berr != nil || !bok {
				delete(rec_copy, alloc)
				rec_loop_close(&it)
				code := print_tape_error(stderr_w, disp, berr, rec, sp, false, b, rinfo.lo) if berr != nil else EXIT_RUNTIME
				if owned { delete(b, alloc) }
				return code
			}
			if !o.stream { _ = query.append_owned(&w.h, &arr, dv); continue }
			SBridge :: struct { sh: ^Shared_Query_State, w: ^Query_Worker, cfg: ^Render_Config, display: string, fidx: int, emit: engine.Emitter, ee: engine.Exec_Error }
			sbr := SBridge{sh = sh, w = w, cfg = cfg, display = disp, fidx = fidx, emit = emit}
			_ = jq.run_value(&srun, dv, proc(d: rawptr, v: query.Value, _: ^query.Heap) -> bool {
				sb := (^SBridge)(d)
				ee := run_prog_on_value(sb.w, &sb.w.run, v, {file_path = sb.display}, sb.emit, sb.cfg, true)
				merge_worker_outcome(sb.sh, sb.w, {file_idx = sb.fidx}, ee, true)
				if ee != .None { sb.ee = ee; return false }
				return true
			}, &sbr)
			if sbr.ee != .None {
				rec_loop_close(&it)
				if owned { delete(b, alloc) }
				return finalize_shared_status(o, sh, osink, stderr_w)
			}
		}
		tail_err := it.tail_err
		rec_loop_close(&it)
		if tail_err != nil {
			if serr_mode {
				emit_stream_err(w, tail_err, disp, b, e.format, emit, cfg)
			} else {
				if owned { delete(b, alloc) }
				return EXIT_RUNTIME
			}
		}
		if owned { delete(b, alloc) }
	}
	if o.stream { return EXIT_USAGE if has_open_err else finalize_shared_status(o, sh, osink, stderr_w) }

	run_arr := arr
	arr = query.ABSENT
	ee := run_prog_on_value(w, &w.run, run_arr, {file_path = "<stdin>" if (len(paths) == 0 || paths[0] == "-") else paths[0]}, emit, cfg, true)
	merge_worker_outcome(sh, w, {}, ee, true)
	if ee == .Halted { return finalize_shared_status(o, sh, osink, stderr_w) }
	if has_open_err { return EXIT_USAGE }
	if had_bad && o.skip_bad { return EXIT_RUNTIME }
	return finalize_shared_status(o, sh, osink, stderr_w)
}

// ---- Finalization & Error Reporting ----

@(private = "file")
finalize_shared_status :: proc(o: ^Options, sh: ^Shared_Query_State, osink: ^Out_Stream, stderr_w: io.Writer) -> int {
	if osink != nil && osink.failed { return report_out_stream_error(osink, stderr_w) }
	sync.mutex_guard(&sh.merge_lock)
	m := &sh.merge
	if m.has_err {
		switch m.err_kind {
		case .None, .Stopped:
		case .Halted:
			if m.halt_msg != "" && stderr_w.procedure != nil { _, _ = io.write_string(stderr_w, m.halt_msg) }
			return m.halt_code
		case .Failed, .Tainted, .Read_Error, .Write_Error, .Unsupported, .No_Memory:
			if m.err_msg != "" && stderr_w.procedure != nil { fmt.wprintf(stderr_w, "jq: error: %s\n", m.err_msg) }
			return EXIT_RUNTIME
		}
	}
	if o.exit_status {
		if m.total_emitted == 0 { return EXIT_NO_OUTPUT }
		if m.last_falsy { return EXIT_FALSY }
	}
	return EXIT_OK
}

@(private = "file")
handle_shared_result :: proc(o: ^Options, sh: ^Shared_Query_State, res: engine.Exec_Result, file: string, src: []u8, sp: engine.Spec, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	switch res.err {
	case .None, .Stopped:
		return finalize_shared_status(o, sh, sh.osink, stderr_w)
	case .Halted:
		sync.mutex_guard(&sh.merge_lock)
		if sh.merge.halt_msg != "" && stderr_w.procedure != nil { _, _ = io.write_string(stderr_w, sh.merge.halt_msg) }
		return sh.merge.halt_code
	case .Read_Error:
		return print_tape_error(stderr_w, file, res.read_err, src, sp)
	case .Write_Error:
		sync.mutex_guard(&sh.merge_lock)
		if sh.merge.err_msg != "" {
			if sh.is_jp { fmt.wprintf(stderr_w, "stury: error (%s): %s\n", file, sh.merge.err_msg) } else { fmt.wprintf(stderr_w, "stury: error: %s\n", sh.merge.err_msg) }
			return EXIT_RUNTIME
		}
		msg := write_error_string(res.write_err, alloc)
		fmt.wprintf(stderr_w, "stury: error: %s\n", msg)
		delete(msg, alloc)
		return EXIT_RUNTIME
	case .Failed, .Tainted, .Unsupported, .No_Memory:
		sync.mutex_guard(&sh.merge_lock)
		if sh.is_jp {
			if sh.merge.err_msg != "" { fmt.wprintf(stderr_w, "stury: error (%s): %s\n", file, sh.merge.err_msg) } else { fmt.wprintf(stderr_w, "stury: jsonpath runtime error (%s)\n", file) }
		} else {
			msg := sh.merge.err_msg if (sh.merge.has_err && sh.merge.err_msg != "") else "execution failed"
			fmt.wprintf(stderr_w, "jq: error (at %s): %s\n", file, msg)
		}
		return EXIT_RUNTIME
	}
	return EXIT_RUNTIME
}

// ---- Unified Top-Level Query Entrypoint (JQ & JSONPath) ----

run_query :: proc(
	o: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	base_runner: ^tape.Runner,
	exe_dir, origin_dir, home_dir: string,
	alloc: runtime.Allocator,
) -> int {
	to_e, to_ok := engine.entry_of_spec(o.to_spec)
	cfg := Render_Config{
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
		if !cok { fmt.wprintln(stderr_w, "Failed to set $JQ_COLORS") }
		cfg.colors, cfg.colors_owned = c, co
	}
	defer render_config_destroy(&cfg, alloc)

	osink: Out_Stream
	out_stream_init(&osink, stdout_w, o.unbuffered, cfg.color)

	jq_prog: ^jq.Program
	jq_plan: jq.Plan
	jp_prog: ^jsonpath.Program
	plan_ptr: ^query.Plan
	sh: ^Shared_Query_State

	if o.jsonpath {
		jp_src := o.filter.? or_else "$"
		cerr: jsonpath.Compile_Error
		jp_prog, cerr = jsonpath.compile(jp_src, {max_depth = int(o.budget.depth)}, alloc)
		if cerr.kind != .None {
			jsonpath.destroy_program(jp_prog)
			print_located_error(stderr_w, "stury: jsonpath error", "<jsonpath>", transmute([]u8)jp_src, u64(max(cerr.offset, 0)), cerr.message)
			return EXIT_COMPILE
		}
		plan_ptr = &jp_prog.plan
		sh = shared_query_init_base(o, &cfg, &osink, stderr_w, alloc)
		sh.is_jp, sh.jp_prog = true, jp_prog
	} else {
		cok: bool
		ccode: int
		jq_prog, _, cok, ccode = compile_jq_cmd(o, exe_dir, origin_dir, home_dir, stderr_w, alloc)
		if !cok { return ccode }
		aopts := jq.Analyze_Options{null_input = o.null_input, slurp = o.slurp, raw_input = o.raw_input, stream = o.stream, materialize_each = true}
		if len(o.with_sources) > 0 {
			ext_names := make([]string, len(o.with_sources), alloc)
			for ws, i in o.with_sources { ext_names[i] = ws.name }
			jq_plan, _ = jq.analyze_plan_with_vars(jq_prog, ext_names, aopts, alloc)
			delete(ext_names, alloc)
		} else {
			jq_plan = jq.analyze(jq_prog, aopts, alloc)
		}
		plan_ptr = &jq_plan.contract
		serr: string
		sh, serr = shared_query_init_jq(o, &cfg, jq_prog, &jq_plan, &osink, stderr_w, alloc)
		if serr != "" {
			jq.destroy_plan(&jq_plan)
			jq.destroy_program(jq_prog)
			fmt.wprintf(stderr_w, "stury: error: %s\n", serr)
			delete(serr, alloc)
			return EXIT_USAGE
		}
	}
	defer {
		shared_query_destroy(sh)
		if o.jsonpath { jsonpath.destroy_program(jp_prog) } else { jq.destroy_plan(&jq_plan); jq.destroy_program(jq_prog) }
	}

	xml_sc: ^schema.Compiled
	if o.xml_arrays == .Schema && o.schema_file != "" {
		sc_ok: bool
		xml_sc, _, sc_ok = compile_schema_file(o, o.schema_file, stderr_w, alloc)
		if !sc_ok { return EXIT_USAGE }
		sh.xml_schema_desc = xml_sc.description
	}
	defer schema.destroy(xml_sc)

	if !o.jsonpath && len(o.with_sources) > 0 {
		if acode := load_shared_aux(sh, o, plan_ptr, stderr_w, alloc); acode != EXIT_OK { return acode }
	}

	worker, wok := new_query_worker(sh, sh.locked_alloc, true)
	if !wok { fmt.wprintln(stderr_w, "stury: error: out of memory"); return EXIT_RUNTIME }
	sh.serial_worker = worker
	defer free_query_worker(worker)

	pin: Plan_Pin_State
	if !plan_pin_init(&pin, o, stderr_w, alloc) { return EXIT_USAGE }
	defer plan_pin_destroy(&pin)

	qw: Quarantine_Writer
	if !o.jsonpath && o.quarantine != "" && !quarantine_open(&qw, o.quarantine, stderr_w, alloc) { return EXIT_USAGE }
	defer quarantine_close(&qw, stderr_w)

	fb := [1]string{"-"}
	paths := o.files[:] if len(o.files) > 0 else fb[:]
	parallel_allowed := o.threads != 1 && (!cfg.to_tabular || can_direct_tabular(o, &cfg, o.to_spec)) && !cfg.one_doc && cfg.to_render == .None && !o.unbuffered
	parallel_min_bytes := parallel_min_bytes_of(o)
	lazy_pool: host.Pool
	has_lazy_pool := false
	defer if has_lazy_pool { host.pool_destroy(&lazy_pool) }
	runner := ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o) if (parallel_allowed && (base_runner != nil || (o.threads > 1 && (o.explain || o.plan_out != "" || o.plan_file != "")))) else nil
	emit := engine.Emitter{fn = out_sink_emit, data = &osink}

	if !o.jsonpath {
		if o.each {
			code := run_jq_each_files(o, &cfg, plan_ptr, sh, worker, &osink, emit, &qw, &pin, paths, stdin_override, base_runner, &lazy_pool, &has_lazy_pool, parallel_allowed, parallel_min_bytes, stderr_w, alloc)
			if osink.failed || !out_stream_flush(&osink) { return report_out_stream_error(&osink, stderr_w) }
			return EXIT_USAGE if qw.write_failed else code
		}
		if o.null_input {
			has_in_files := len(o.files) > 0 || (.Inputs in jq_plan.serial) || (.Position in jq_plan.serial)
			hpaths := paths if (has_in_files && len(o.files) > 0) else (fb[:] if (.Inputs in jq_plan.serial) else nil)
			ee, ncode, oerr, pfail := run_null_input(o, &cfg, plan_ptr, sh, worker, &osink, emit, &pin, hpaths, stdin_override, runner, stderr_w, alloc)
			if pfail { return ncode }
			flush_null := (ee == .None || (ee == .Halted && worker.halt_code == 0)) && !oerr
			code := flush_and_teardown(worker, &osink, stderr_w, alloc, EXIT_USAGE if oerr else ncode, flush_null)
			return code
		}
		if o.raw_input || o.slurp || o.stream {
			code := run_jq_special(o, &cfg, plan_ptr, sh, worker, &osink, emit, &qw, &pin, paths, stdin_override, runner, stderr_w, alloc)
			code = flush_and_teardown(worker, &osink, stderr_w, alloc, code, code == EXIT_OK || (o.exit_status && code == EXIT_FALSY))
			return EXIT_USAGE if qw.write_failed else code
		}
		if len(paths) == 1 && paths[0] == "-" && stdin_override == nil {
			if handled, bad_s, scode := stream_stdin_delim(o, &cfg, plan_ptr, worker, &osink, emit, &qw, &pin, stderr_w, alloc); handled {
				scode = flush_and_teardown(worker, &osink, stderr_w, alloc, scode, scode == EXIT_OK && !(bad_s && o.skip_bad))
				if qw.write_failed { return EXIT_USAGE }
				if scode != EXIT_OK { return scode }
				return EXIT_RUNTIME if (bad_s && o.skip_bad) else finalize_shared_status(o, sh, &osink, stderr_w)
			}
		}

		// Check `.Files_Parallel` eligibility when multiple homogeneous regular files are passed.
		same_spec := len(paths) > 1
		if same_spec {
			base_sp, _ := detect_file_spec(o, paths[0])
			for p in paths[1:] {
				if psp, _ := detect_file_spec(o, p); psp != base_sp { same_spec = false; break }
			}
		}
		direct_guard := plan_ptr.hints.projection.shape != .None && projection_direct_blocked(o, &cfg, 1)
		if same_spec && parallel_allowed && plan_ptr.serial == {} && !cfg.to_tabular && !cfg.one_doc && cfg.to_render == .None && !direct_guard && !o.skip_bad && !o.seq && !o.where_mode && o.xml_arrays == .Auto && total_regular_bytes_small(paths, alloc) {
			finputs := make([]engine.File_Input, len(paths), alloc)
			loaded_n, open_failed := 0, false
			for p, idx in paths {
				b, _, rok := read_input_bytes(p, stdin_override, io.Writer{}, alloc)
				if !rok { open_failed = true; break }
				sp, fr := detect_file_spec(o, p)
				if e, ok_e := engine.entry_of_spec(sp); ok_e && e.id == .Json && fr == .Single { fr = .Concatenated }
				finputs[idx] = {path = p, src = b, spec = sp, framing = fr}
				loaded_n = idx + 1
			}
			if open_failed {
				for i in 0 ..< loaded_n { delete(finputs[i].src, alloc) }
				delete(finputs, alloc)
			} else {
				defer {
					for fi in finputs { delete(fi.src, alloc) }
					delete(finputs, alloc)
				}
				runner = ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o)
				if o.explain || o.plan_out != "" || o.plan_file != "" {
					fdec, _ := decide_file_route(o, &cfg, plan_ptr, finputs[0].spec, finputs[0].framing, len(finputs[0].src), runner, len(finputs), sh.each_prog != nil, sh.pred_prog != nil, stderr_w, alloc)
					if pcode := plan_pin_apply(&pin, &fdec, stderr_w, alloc); pcode != EXIT_OK { return pcode }
				}
				ro := read_opts_of(o, finputs[0].spec, runner)
				use_direct_par := plan_ptr.hints.projection.shape != .None && !cfg.to_non_json && cfg.to_render == .None && !cfg.join && !cfg.raw0
				par_emit := engine.Emitter{fn = direct_nl_emit, data = &osink} if use_direct_par else emit
				f_eopts := make_exec_opts(o, &cfg, plan_ptr, sh, worker, par_emit, ro, runner, nil, nil, false, 0, "")
				res := engine.execute_files(plan_ptr, finputs, {runner = runner, where_mode = o.where_mode, dups = o.dups, allow_rerun_whole = true, serial_eval_ctx = cfg.one_doc}, f_eopts)
				if osink.failed || !out_stream_flush(&osink) { return report_out_stream_error(&osink, stderr_w) }
				err_fi := finputs[0]
				if res.err == .Read_Error {
					err_fi = finputs[find_files_read_error(o, plan_ptr, finputs, ro, sh.locked_alloc)]
				} else if res.err != .None && res.err != .Stopped {
					sync.mutex_lock(&sh.merge_lock)
					k := sh.merge.err_key.file_idx
					sync.mutex_unlock(&sh.merge_lock)
					if k >= 0 && k < len(finputs) { err_fi = finputs[k] }
				}
				return handle_shared_result(o, sh, res, err_fi.path, err_fi.src, err_fi.spec, stderr_w, alloc)
			}
		}
	}

	// Sequential per-file streaming loop (shared by both jq and JSONPath!).
	has_open_err, has_exec_err, had_bad := false, false, false
	bad_ctx: Quarantine_Bad_Ctx
	for p, fidx in paths {
		b, owned, rok := read_input_bytes(p, stdin_override, stderr_w, alloc)
		if !rok { has_open_err = true; continue }
		disp := "<stdin>" if p == "-" else p
		sp, fr := detect_file_spec(o, p)
		cur_runner := ensure_lazy_pool(base_runner, &lazy_pool, &has_lazy_pool, o) if (runner == nil && parallel_allowed && len(b) >= parallel_min_bytes) else runner

		res, pin_code := exec_query_on_bytes(o, &cfg, plan_ptr, sh, worker, &osink, emit, &qw, cur_runner, b, disp, sp, fr, fidx, len(paths), &bad_ctx, &pin, stderr_w, alloc)
		if pin_code != EXIT_OK {
			if owned { delete(b, alloc) }
			return flush_and_teardown(worker, &osink, stderr_w, alloc, EXIT_USAGE if has_open_err else pin_code, false)
		}
		if res.bad_records > 0 && o.skip_bad { had_bad = true }
		if res.err != .None && res.err != .Stopped {
			fcode := handle_shared_result(o, sh, res, disp, b, sp, stderr_w, alloc)
			if owned { delete(b, alloc) }
			if res.err == .Halted {
				return flush_and_teardown(worker, &osink, stderr_w, alloc, fcode, fcode == EXIT_OK && !has_open_err)
			}
			has_exec_err = true
			if o.jsonpath || !o.skip_bad {
				return flush_and_teardown(worker, &osink, stderr_w, alloc, EXIT_USAGE if has_open_err else fcode, false)
			}
		} else if owned {
			delete(b, alloc)
		}
		if osink.failed { return report_out_stream_error(&osink, stderr_w) }
	}

	flush_end := !has_open_err && !has_exec_err && !(had_bad && o.skip_bad) && !qw.write_failed
	if tcode := finish_query_writers(worker, &osink, stderr_w, alloc, flush_render = flush_end); tcode != EXIT_OK {
		if osink.failed || !out_stream_flush(&osink) { return report_out_stream_error(&osink, stderr_w) }
		return tcode
	}
	if !out_stream_flush(&osink) { return report_out_stream_error(&osink, stderr_w) }
	if qw.write_failed || has_open_err { return EXIT_USAGE }
	if has_exec_err || (had_bad && o.skip_bad) { return EXIT_RUNTIME }
	return finalize_shared_status(o, sh, &osink, stderr_w)
}
