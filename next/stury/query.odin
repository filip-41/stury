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

// jq frontend types and compile/destroy entry points.
Jq_Program :: jq.Program
Jq_Compile_Options :: jq.Compile_Options
Jq_Compile_Error :: jq.Compile_Error
Jq_Run_End :: jq.Run_End
jq_compile :: jq.compile
jq_destroy :: jq.destroy_program

// JSONPath frontend types and compile/destroy entry points.
Jsonpath_Program :: jsonpath.Program
Jsonpath_Compile_Options :: jsonpath.Compile_Options
Jsonpath_Compile_Error :: jsonpath.Compile_Error
Jsonpath_Run_End :: jsonpath.Run_End
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

// Receives each compact JSON output emitted by `jq_run` / `jq_run_doc`. Return `false` to stop early.
Jq_Emit_Proc :: #type proc(ctx: rawptr, json_bytes: []u8) -> bool

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

// Receives each compact JSON value and optional RFC 9535 normalized path emitted by `jsonpath_eval` / `jsonpath_eval_doc`.
// Return `false` to stop early.
Jsonpath_Emit_Proc :: #type proc(ctx: rawptr, json_bytes: []u8, norm_path: string) -> bool

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
merge_budget :: proc "contextless" (base, override: tape.Budget) -> tape.Budget {
	b := base
	if override.depth != 0 {
		b.depth = override.depth
	}
	if override.nodes != 0 {
		b.nodes = override.nodes
	}
	if override.memory != 0 {
		b.memory = override.memory
	}
	if override.steps != 0 {
		b.steps = override.steps
	}
	if override.expansion != 0 {
		b.expansion = override.expansion
	}
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
Jq_Eval_State :: struct {
	prog:       ^jq.Program,
	budget:     tape.Budget,
	alloc:      runtime.Allocator,
	emit:       engine.Emitter,
	buf:        [dynamic]u8,
	err_kind:   Query_Error,
	err_msg:    string,
	err_owned:  bool,
	write_fail: bool,
}

@(private = "file")
jq_value_sink :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
	st := (^Jq_Eval_State)(data)
	defer query.release(h, v)
	clear(&st.buf)
	if query.write_json(h, &st.buf, v) != .Ok {
		st.write_fail = true
		return false
	}
	return engine.emit_bytes(st.emit, st.buf[:])
}

@(private = "file")
jq_eval_doc_cb :: proc(ctx: rawptr, doc: ^tape.Document, _: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	st := (^Jq_Eval_State)(ctx)
	st.emit = emit
	st.write_fail = false
	st.err_kind = .None

	h: query.Heap
	query.heap_init(&h, st.alloc, st.budget.memory, clamp_depth(st.budget.depth))
	defer query.heap_destroy(&h)

	input, status := query.document_value(&h, doc^, owned = false)
	if status != .Ok {
		st.err_kind = memory_err_kind(st.budget)
		return .Failed if st.err_kind == .Exceeded else .No_Memory
	}

	hooks := jq.Hooks {
		markup     = jq_markup_hook,
		parse_json = jq_parse_json_hook,
	}
	steps := int(min(st.budget.steps, u64(max(int))))
	run: jq.Run
	jq.run_init(&run, st.prog, &h, nil, &hooks, steps)
	defer jq.run_destroy(&run)

	end := jq.run_value(&run, input, jq_value_sink, st)
	switch end {
	case .Done:
		return .None
	case .Stopped:
		if st.write_fail {
			e := query.take_error(&h)
			defer query.destroy_error(&h, &e)
			if e.kind == .Memory {
				st.err_kind = memory_err_kind(st.budget)
				return .Failed if st.err_kind == .Exceeded else .No_Memory
			}
			if e.kind == .Depth || e.kind == .Budget {
				st.err_kind = .Exceeded
				return .Failed
			}
			st.err_kind = .Write_Error
			return .Write_Error
		}
		return .Stopped
	case .Halted:
		st.err_kind = .Halted
		return .Halted
	case .Tainted:
		return .Tainted
	case .Failed:
		e := query.take_error(&h)
		defer query.destroy_error(&h, &e)
		switch e.kind {
		case .Memory:
			st.err_kind = memory_err_kind(st.budget)
		case .Budget, .Depth:
			st.err_kind = .Exceeded
		case .None, .Raised, .Zero_Divisor, .Types, .Range, .Parse, .Pattern:
			st.err_kind = .Failed
		}
		if st.err_owned && len(st.err_msg) > 0 {
			delete(st.err_msg, st.alloc)
			st.err_msg = ""
			st.err_owned = false
		}
		msg := jq.error_message(&h, &e, st.alloc)
		if len(msg) > 0 {
			st.err_msg = msg
			st.err_owned = true
		}
		return .No_Memory if st.err_kind == .No_Memory else .Failed
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
) -> (
	res: Jq_Run_Result,
) {
	res.allocator = allocator
	if prog == nil {
		res.err = .Bad_Option
		res.message = "nil jq program"
		return res
	}
	if _, ok := engine.entry_of_spec(spec); !ok {
		res.err = .Bad_Option
		res.message = "invalid format spec"
		return res
	}

	plan := jq.analyze(prog, {}, allocator)
	defer query.destroy_plan(&plan.contract)

	eff_read := opts.read
	eff_read.budget = merge_budget(opts.read.budget, opts.budget)

	route_opts := engine.Route_Options {
		dups              = eff_read.dups,
		input_bytes       = len(src),
		serial_eval_ctx   = true,
		allow_rerun_whole = true,
	}
	dec := engine.decide(&plan.contract, spec, opts.framing, route_opts)
	// Enforce explicit step or memory budgets (from either `opts.budget` or `opts.read.budget`) through the evaluator.
	if eff_read.budget.steps > 0 || eff_read.budget.memory > 0 {
		downgrade_projection_direct(&dec)
	}

	st := Jq_Eval_State {
		prog   = prog,
		budget = eff_read.budget,
		alloc  = allocator,
		buf    = make([dynamic]u8, 0, 256, allocator),
	}
	defer delete(st.buf)

	exec_opts := engine.Exec_Options {
		eval                 = jq_eval_doc_cb,
		eval_ctx             = rawptr(&st),
		emit                 = {fn = emit, data = emit_ctx},
		read                 = eff_read,
		rerun_whole_on_taint = true,
		allocator            = allocator,
	}
	eres := engine.execute(&plan.contract, &dec, src, exec_opts)
	res.emitted = eres.emitted
	res.read_err = eres.read_err
	res.message = st.err_msg
	res.message_owned = st.err_owned
	res.err = map_exec_error(eres, st.err_kind)
	return res
}

// Runs compiled jq program `prog` against an already-built `doc`, emitting compact JSON outputs to `emit`.
@(require_results)
jq_run_doc :: proc(
	prog: ^Jq_Program,
	doc: ^Document,
	emit: Jq_Emit_Proc,
	emit_ctx: rawptr = nil,
	budget := tape.Budget{},
	allocator := context.allocator,
) -> (
	res: Jq_Run_Result,
) {
	res.allocator = allocator
	if prog == nil || doc == nil {
		res.err = .Bad_Option
		res.message = "nil program or document"
		return res
	}
	st := Jq_Eval_State {
		prog   = prog,
		budget = budget,
		alloc  = allocator,
		buf    = make([dynamic]u8, 0, 256, allocator),
	}
	defer delete(st.buf)

	Counter :: struct {
		inner:   Jq_Emit_Proc,
		ctx:     rawptr,
		emitted: u64,
	}
	cnt := Counter{inner = emit, ctx = emit_ctx}
	cnt_fn :: proc(data: rawptr, b: []u8) -> bool {
		c := (^Counter)(data)
		if c.inner != nil && !c.inner(c.ctx, b) {
			return false
		}
		c.emitted += 1
		return true
	}
	ee := jq_eval_doc_cb(&st, doc, {}, {fn = cnt_fn, data = &cnt})
	res.emitted = cnt.emitted
	res.message = st.err_msg
	res.message_owned = st.err_owned
	res.err = map_exec_error({err = ee}, st.err_kind)
	return res
}

@(private = "file")
Jsonpath_Eval_State :: struct {
	prog:          ^jsonpath.Program,
	want_paths:    bool,
	budget:        tape.Budget,
	alloc:         runtime.Allocator,
	user_emit:     Jsonpath_Emit_Proc,
	user_ctx:      rawptr,
	guard_emit:    engine.Emitter,
	cur_norm_path: string,
	buf:           [dynamic]u8,
	h:             ^query.Heap,
	err_kind:      Query_Error,
	write_fail:    bool,
}

@(private = "file")
jsonpath_bridge_emit :: proc(data: rawptr, bytes: []u8) -> bool {
	st := (^Jsonpath_Eval_State)(data)
	if st.user_emit == nil {
		return true
	}
	return st.user_emit(st.user_ctx, bytes, st.cur_norm_path)
}

@(private = "file")
jsonpath_value_sink :: proc(data: rawptr, v: query.Value, norm_path: string) -> bool {
	st := (^Jsonpath_Eval_State)(data)
	defer query.release(st.h, v)
	clear(&st.buf)
	if query.write_json(st.h, &st.buf, v) != .Ok {
		st.write_fail = true
		return false
	}
	st.cur_norm_path = norm_path
	return engine.emit_bytes(st.guard_emit, st.buf[:])
}

@(private = "file")
jsonpath_eval_doc_cb :: proc(ctx: rawptr, doc: ^tape.Document, _: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
	st := (^Jsonpath_Eval_State)(ctx)
	st.guard_emit = emit
	st.cur_norm_path = ""
	st.write_fail = false
	st.err_kind = .None

	h: query.Heap
	query.heap_init(&h, st.alloc, st.budget.memory, clamp_depth(st.budget.depth))
	defer query.heap_destroy(&h)
	st.h = &h
	defer st.h = nil

	root, status := query.document_value(&h, doc^, owned = false)
	if status != .Ok {
		st.err_kind = memory_err_kind(st.budget)
		return .Failed if st.err_kind == .Exceeded else .No_Memory
	}
	defer query.release(&h, root)

	end := jsonpath.eval(
		st.prog,
		&h,
		root,
		jsonpath_value_sink,
		st,
		{want_paths = st.want_paths, budget = st.budget},
	)
	switch end {
	case .Done:
		return .None
	case .Stopped:
		if st.write_fail {
			e := query.take_error(&h)
			defer query.destroy_error(&h, &e)
			if e.kind == .Memory {
				st.err_kind = memory_err_kind(st.budget)
				return .Failed if st.err_kind == .Exceeded else .No_Memory
			}
			if e.kind == .Depth || e.kind == .Budget {
				st.err_kind = .Exceeded
				return .Failed
			}
			st.err_kind = .Write_Error
			return .Write_Error
		}
		return .Stopped
	case .Tainted:
		return .Tainted
	case .Exceeded:
		st.err_kind = .Exceeded
		return .Failed
	case .Failed:
		e := query.take_error(&h)
		defer query.destroy_error(&h, &e)
		if e.kind == .Memory {
			st.err_kind = memory_err_kind(st.budget)
			return .Failed if st.err_kind == .Exceeded else .No_Memory
		}
		st.err_kind = .Failed
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
) -> (
	res: Jsonpath_Eval_Result,
) {
	if prog == nil {
		res.err = .Bad_Option
		return res
	}
	if _, ok := engine.entry_of_spec(spec); !ok {
		res.err = .Bad_Option
		return res
	}

	eff_read := opts.read
	eff_read.budget = merge_budget(opts.read.budget, opts.budget)

	route_opts := engine.Route_Options {
		dups              = eff_read.dups,
		input_bytes       = len(src),
		serial_eval_ctx   = true,
		allow_rerun_whole = true,
	}
	dec := engine.decide(&prog.plan, spec, opts.framing, route_opts)
	// RFC 9535 omits absent nodes (unlike jq's null projection) and may request normalized paths,
	// so run through the JSONPath evaluator while still leveraging partial `Scan` / framed routes.
	downgrade_projection_direct(&dec)

	st := Jsonpath_Eval_State {
		prog       = prog,
		want_paths = opts.want_paths,
		budget     = eff_read.budget,
		alloc      = allocator,
		user_emit  = emit,
		user_ctx   = emit_ctx,
		buf        = make([dynamic]u8, 0, 256, allocator),
	}
	defer delete(st.buf)

	exec_opts := engine.Exec_Options {
		eval                 = jsonpath_eval_doc_cb,
		eval_ctx             = rawptr(&st),
		emit                 = {fn = jsonpath_bridge_emit, data = rawptr(&st)},
		read                 = eff_read,
		rerun_whole_on_taint = true,
		allocator            = allocator,
	}
	eres := engine.execute(&prog.plan, &dec, src, exec_opts)
	res.emitted = eres.emitted
	res.read_err = eres.read_err
	res.err = map_exec_error(eres, st.err_kind)
	return res
}

// Evaluates compiled RFC 9535 JSONPath `prog` against an already-built `doc`.
@(require_results)
jsonpath_eval_doc :: proc(
	prog: ^Jsonpath_Program,
	doc: ^Document,
	emit: Jsonpath_Emit_Proc,
	emit_ctx: rawptr = nil,
	want_paths := false,
	budget := tape.Budget{},
	allocator := context.allocator,
) -> (
	res: Jsonpath_Eval_Result,
) {
	if prog == nil || doc == nil {
		res.err = .Bad_Option
		return res
	}
	st := Jsonpath_Eval_State {
		prog       = prog,
		want_paths = want_paths,
		budget     = budget,
		alloc      = allocator,
		user_emit  = emit,
		user_ctx   = emit_ctx,
		buf        = make([dynamic]u8, 0, 256, allocator),
	}
	defer delete(st.buf)

	Counter :: struct {
		st:      ^Jsonpath_Eval_State,
		emitted: u64,
	}
	cnt := Counter{st = &st}
	cnt_fn :: proc(data: rawptr, b: []u8) -> bool {
		c := (^Counter)(data)
		if !jsonpath_bridge_emit(c.st, b) {
			return false
		}
		c.emitted += 1
		return true
	}
	ee := jsonpath_eval_doc_cb(&st, doc, {}, {fn = cnt_fn, data = &cnt})
	res.emitted = cnt.emitted
	res.err = map_exec_error({err = ee}, st.err_kind)
	return res
}

@(private = "file")
map_exec_error :: proc "contextless" (eres: engine.Exec_Result, inner: Query_Error) -> Query_Error {
	if eres.err == .None {
		return .None
	}
	if inner != .None {
		return inner
	}
	switch eres.err {
	case .None:
		return .None
	case .Stopped:
		return .Stopped
	case .Failed:
		return .Failed
	case .Halted:
		return .Halted
	case .Tainted:
		return .Tainted
	case .Read_Error:
		if _, is_exc := eres.read_err.(tape.Exceeded); is_exc {
			return .Exceeded
		}
		return .Read_Error
	case .Write_Error:
		return .Write_Error
	case .Unsupported:
		return .Bad_Option
	case .No_Memory:
		return .No_Memory
	}
	return .Failed
}

// Formats compile errors from `jq_compile` into a single diagnostic string owned by `allocator`.
jq_compile_error_message :: proc(errors: []Jq_Compile_Error, allocator := context.allocator) -> string {
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
