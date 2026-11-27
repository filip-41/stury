package stury

import "base:runtime"
import "core:strings"
import "stury:engine"
import "stury:jq"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/core/tape"
import ops_css "stury:lib/ops/css"
import "stury:lib/query"

// Query frontend convenience wrappers (`jq` and RFC 9535 `jsonpath`) routed through `stury:engine`.

// jq frontend compile/destroy entry points.
Jq_Program :: jq.Program
jq_compile :: jq.compile
jq_destroy :: jq.destroy_program

// JSONPath frontend compile/destroy entry points.
Jsonpath_Program :: jsonpath.Program
jsonpath_compile :: jsonpath.compile
jsonpath_destroy :: jsonpath.destroy_program

Query_Error :: enum u8 {
	None,
	Stopped,
	Failed,
	Halted,
	Tainted,
	Read_Error,
	Write_Error,
	Exceeded,
	No_Memory,
	Bad_Option,
}

Jq_Run_Options :: struct {
	read:    tape.Options,
	budget:  tape.Budget,
	framing: engine.Framing,
}

Jq_Run_Result :: struct {
	err:           Query_Error,
	emitted:       u64,
	read_err:      tape.Error,
	message:       string,
	message_owned: bool,
	allocator:     runtime.Allocator,
}

jq_run_result_destroy :: proc(res: ^Jq_Run_Result) {
	if res == nil {
		return
	}
	if res.message_owned && len(res.message) > 0 {
		delete(res.message, res.allocator)
	}
	res^ = {}
}

Jsonpath_Eval_Options :: struct {
	want_paths: bool,
	read:       tape.Options,
	budget:     tape.Budget,
	framing:    engine.Framing,
}

Jsonpath_Eval_Result :: struct {
	err:      Query_Error,
	emitted:  u64,
	read_err: tape.Error,
}

@(private = "file")
Jq_Emit_Proc :: #type proc(ctx: rawptr, json_bytes: []u8) -> bool

@(private = "file")
Jsonpath_Emit_Proc :: #type proc(ctx: rawptr, json_bytes: []u8, norm_path: string) -> bool

@(private = "file")
merge_budget :: proc "contextless" (base, override: tape.Budget) -> tape.Budget {
	b := base
	if override.depth != 0 { b.depth = override.depth }
	if override.nodes != 0 { b.nodes = override.nodes }
	if override.memory != 0 { b.memory = override.memory }
	if override.steps != 0 { b.steps = override.steps }
	if override.expansion != 0 { b.expansion = override.expansion }
	return b
}

@(private = "file")
clamp_depth :: #force_inline proc "contextless" (d: u32) -> int {
	return int(min(u64(d), u64(max(int))))
}

@(private = "file")
memory_err_kind :: #force_inline proc "contextless" (budget: tape.Budget) -> Query_Error {
	return .Exceeded if budget.memory > 0 else .No_Memory
}

@(private = "file")
downgrade_projection_direct :: proc "contextless" (dec: ^engine.Decision) {
	if dec.kind != .Projection_Direct {
		return
	}
	if dec.framing != .Single {
		dec.kind = .Records_Serial
	} else if dec.entry.supports_scan && dec.demand_mode == .Partial {
		dec.kind = .Scan
	} else {
		dec.kind = .Whole
	}
}

@(private = "file")
query_route :: proc(plan: ^query.Plan, spec: Spec, framing: engine.Framing, read: tape.Options, budget: tape.Budget, src_len: int) -> (eff_read: tape.Options, dec: engine.Decision) {
	eff_read = read
	eff_read.budget = merge_budget(read.budget, budget)
	route_opts := engine.Route_Options {
		dups              = eff_read.dups,
		input_bytes       = src_len,
		serial_eval_ctx   = true,
		allow_rerun_whole = true,
	}
	dec = engine.decide(plan, spec, framing, route_opts)
	return
}

@(private = "file")
classify_write_fail :: proc(h: ^query.Heap, budget: tape.Budget) -> (Query_Error, engine.Exec_Error) {
	e := query.take_error(h)
	defer query.destroy_error(h, &e)
	if e.kind == .Memory {
		k := memory_err_kind(budget)
		return k, .Failed if k == .Exceeded else .No_Memory
	}
	if e.kind == .Depth || e.kind == .Budget {
		return .Exceeded, .Failed
	}
	return .Write_Error, .Write_Error
}

@(private = "file")
jq_markup_hook :: proc(_: rawptr, doc: ^tape.Document) -> (ops_css.Options, bool) {
	if doc == nil || doc.format == nil || doc.format.attribute == nil {
		return {}, false
	}
	return {attribute = doc.format.attribute}, true
}

@(private = "file")
jq_parse_json_hook :: proc(_: rawptr, src: []u8, budget: tape.Budget, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	return json.build(src, .Json, {budget = budget}, allocator)
}

@(private = "file")
Query_Eval_Base :: struct {
	budget:     tape.Budget,
	alloc:      runtime.Allocator,
	emit:       engine.Emitter,
	buf:        [dynamic]u8,
	err_kind:   Query_Error,
	write_fail: bool,
}

@(private = "file")
emit_query_value :: proc(base: ^Query_Eval_Base, h: ^query.Heap, v: query.Value) -> bool {
	defer query.release(h, v)
	clear(&base.buf)
	if query.write_json(h, &base.buf, v) != .Ok {
		base.write_fail = true
		return false
	}
	return engine.emit_bytes(base.emit, base.buf[:])
}

@(private = "file")
open_eval_heap :: proc(base: ^Query_Eval_Base, h: ^query.Heap, doc: ^tape.Document, emit: engine.Emitter) -> (val: query.Value, err: engine.Exec_Error) {
	base.emit, base.write_fail, base.err_kind = emit, false, .None
	query.heap_init(h, base.alloc, base.budget.memory, clamp_depth(base.budget.depth))
	v, status := query.document_value(h, doc^, owned = false)
	if status != .Ok {
		base.err_kind = memory_err_kind(base.budget)
		return {}, .Failed if base.err_kind == .Exceeded else .No_Memory
	}
	return v, .None
}

@(private = "file")
finish_stopped :: proc(base: ^Query_Eval_Base, h: ^query.Heap) -> engine.Exec_Error {
	if !base.write_fail {
		return .Stopped
	}
	k, ee := classify_write_fail(h, base.budget)
	base.err_kind = k
	return ee
}

@(private = "file")
Jq_Eval_State :: struct {
	base:      Query_Eval_Base,
	prog:      ^jq.Program,
	err_msg:   string,
	err_owned: bool,
}

@(private = "file")
jq_value_sink :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
	return emit_query_value(&((^Jq_Eval_State)(data)).base, h, v)
}

@(private = "file")
jq_eval_doc_cb :: proc(ctx: rawptr, doc: ^tape.Document, _: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	st := (^Jq_Eval_State)(ctx)
	h: query.Heap
	defer query.heap_destroy(&h)
	input, open_err := open_eval_heap(&st.base, &h, doc, emit)
	if open_err != .None {
		return open_err
	}

	hooks := jq.Hooks{markup = jq_markup_hook, parse_json = jq_parse_json_hook}
	run: jq.Run
	jq.run_init(&run, st.prog, &h, nil, &hooks, int(min(st.base.budget.steps, u64(max(int)))))
	defer jq.run_destroy(&run)

	switch jq.run_value(&run, input, jq_value_sink, st) {
	case .Done:
		return .None
	case .Stopped:
		return finish_stopped(&st.base, &h)
	case .Halted:
		st.base.err_kind = .Halted
		return .Halted
	case .Tainted:
		return .Tainted
	case .Failed:
		e := query.take_error(&h)
		defer query.destroy_error(&h, &e)
		switch e.kind {
		case .Memory:
			st.base.err_kind = memory_err_kind(st.base.budget)
		case .Budget, .Depth:
			st.base.err_kind = .Exceeded
		case .None, .Raised, .Zero_Divisor, .Types, .Range, .Parse, .Pattern:
			st.base.err_kind = .Failed
		}
		if st.err_owned && len(st.err_msg) > 0 {
			delete(st.err_msg, st.base.alloc)
			st.err_msg, st.err_owned = "", false
		}
		if msg := jq.error_message(&h, &e, st.base.alloc); len(msg) > 0 {
			st.err_msg, st.err_owned = msg, true
		}
		return .No_Memory if st.base.err_kind == .No_Memory else .Failed
	}
	return .None
}

// Runs compiled jq program `prog` against `src` in `spec` using `engine` routing and emits compact JSON outputs to `emit`.
// Caller frees any owned error message with `jq_run_result_destroy(&res)`.
@(require_results)
jq_run :: proc(
	prog: ^Jq_Program,
	src: []u8,
	spec: Spec,
	emit: Jq_Emit_Proc,
	emit_ctx: rawptr = nil,
	opts := Jq_Run_Options{},
	allocator := context.allocator,
) -> (res: Jq_Run_Result) {
	res.allocator = allocator
	if prog == nil {
		res.err, res.message = .Bad_Option, "nil jq program"
		return res
	}
	if _, ok := engine.entry_of_spec(spec); !ok {
		res.err, res.message = .Bad_Option, "invalid format spec"
		return res
	}

	plan := jq.analyze(prog, {}, allocator)
	defer query.destroy_plan(&plan.contract)

	eff_read, dec := query_route(&plan.contract, spec, opts.framing, opts.read, opts.budget, len(src))
	if eff_read.budget.steps > 0 || eff_read.budget.memory > 0 {
		downgrade_projection_direct(&dec)
	}

	st := Jq_Eval_State{base = {budget = eff_read.budget, alloc = allocator, buf = make([dynamic]u8, 0, 256, allocator)}, prog = prog}
	defer delete(st.base.buf)

	eres := engine.execute(&plan.contract, &dec, src, {
		eval                 = jq_eval_doc_cb,
		eval_ctx             = rawptr(&st),
		emit                 = {fn = emit, data = emit_ctx},
		read                 = eff_read,
		rerun_whole_on_taint = true,
		allocator            = allocator,
	})
	res.emitted, res.read_err, res.message, res.message_owned = eres.emitted, eres.read_err, st.err_msg, st.err_owned
	res.err = map_exec_error(eres, st.base.err_kind)
	return res
}

@(private = "file")
Jsonpath_Eval_State :: struct {
	base:          Query_Eval_Base,
	prog:          ^jsonpath.Program,
	want_paths:    bool,
	user_emit:     Jsonpath_Emit_Proc,
	user_ctx:      rawptr,
	cur_norm_path: string,
	h:             ^query.Heap,
}

@(private = "file")
jsonpath_bridge_emit :: proc(data: rawptr, bytes: []u8) -> bool {
	st := (^Jsonpath_Eval_State)(data)
	return st.user_emit == nil || st.user_emit(st.user_ctx, bytes, st.cur_norm_path)
}

@(private = "file")
jsonpath_value_sink :: proc(data: rawptr, v: query.Value, norm_path: string) -> bool {
	st := (^Jsonpath_Eval_State)(data)
	st.cur_norm_path = norm_path
	return emit_query_value(&st.base, st.h, v)
}

@(private = "file")
jsonpath_eval_doc_cb :: proc(ctx: rawptr, doc: ^tape.Document, _: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	st := (^Jsonpath_Eval_State)(ctx)
	st.cur_norm_path = ""
	h: query.Heap
	defer query.heap_destroy(&h)
	root, open_err := open_eval_heap(&st.base, &h, doc, emit)
	if open_err != .None {
		return open_err
	}
	defer query.release(&h, root)
	st.h = &h
	defer st.h = nil

	switch jsonpath.eval(st.prog, &h, root, jsonpath_value_sink, st, {want_paths = st.want_paths, budget = st.base.budget}) {
	case .Done:
		return .None
	case .Stopped:
		return finish_stopped(&st.base, &h)
	case .Tainted:
		return .Tainted
	case .Exceeded:
		st.base.err_kind = .Exceeded
		return .Failed
	case .Failed:
		e := query.take_error(&h)
		defer query.destroy_error(&h, &e)
		if e.kind == .Memory {
			st.base.err_kind = memory_err_kind(st.base.budget)
			return .Failed if st.base.err_kind == .Exceeded else .No_Memory
		}
		st.base.err_kind = .Failed
		return .Failed
	}
	return .None
}

// Evaluates compiled RFC 9535 JSONPath `prog` against `src` in `spec` using `engine` routing,
// emitting compact JSON values and optional normalized paths through `engine`'s guarded emitter to `emit`.
@(require_results)
jsonpath_eval :: proc(
	prog: ^Jsonpath_Program,
	src: []u8,
	spec: Spec,
	emit: Jsonpath_Emit_Proc,
	emit_ctx: rawptr = nil,
	opts := Jsonpath_Eval_Options{},
	allocator := context.allocator,
) -> (res: Jsonpath_Eval_Result) {
	if _, ok := engine.entry_of_spec(spec); prog == nil || !ok {
		res.err = .Bad_Option
		return res
	}

	eff_read, dec := query_route(&prog.plan, spec, opts.framing, opts.read, opts.budget, len(src))
	// RFC 9535 omits absent nodes (unlike jq's null projection) and may request normalized paths.
	downgrade_projection_direct(&dec)

	st := Jsonpath_Eval_State {
		base       = {budget = eff_read.budget, alloc = allocator, buf = make([dynamic]u8, 0, 256, allocator)},
		prog       = prog,
		want_paths = opts.want_paths,
		user_emit  = emit,
		user_ctx   = emit_ctx,
	}
	defer delete(st.base.buf)

	eres := engine.execute(&prog.plan, &dec, src, {
		eval                 = jsonpath_eval_doc_cb,
		eval_ctx             = rawptr(&st),
		emit                 = {fn = jsonpath_bridge_emit, data = rawptr(&st)},
		read                 = eff_read,
		rerun_whole_on_taint = true,
		allocator            = allocator,
	})
	return {err = map_exec_error(eres, st.base.err_kind), emitted = eres.emitted, read_err = eres.read_err}
}

@(private = "file")
map_exec_error :: proc "contextless" (eres: engine.Exec_Result, inner: Query_Error) -> Query_Error {
	if eres.err == .None {
		return .None
	}
	if inner != .None {
		return inner
	}
	if eres.err == .Read_Error {
		_, is_exc := eres.read_err.(tape.Exceeded)
		return .Exceeded if is_exc else .Read_Error
	}
	@(static, rodata)
	TABLE := [engine.Exec_Error]Query_Error {
		.None        = .None,
		.Stopped     = .Stopped,
		.Failed      = .Failed,
		.Halted      = .Halted,
		.Tainted     = .Tainted,
		.Read_Error  = .Read_Error,
		.Write_Error = .Write_Error,
		.Unsupported = .Bad_Option,
		.No_Memory   = .No_Memory,
	}
	return TABLE[eres.err]
}

// Formats compile errors from `jq_compile` into a single diagnostic string owned by `allocator`.
jq_compile_error_message :: proc(errors: []jq.Compile_Error, allocator := context.allocator) -> string {
	if len(errors) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	for e, i in errors {
		if i > 0 {
			strings.write_string(&b, "; ")
		}
		strings.write_string(&b, e.msg)
	}
	return strings.to_string(b)
}
