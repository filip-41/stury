package main

// The route a filter takes over each text: the path scan, which answers a path, `first(PATH)`, `limit(N; PATH)` or
// `select(PATH op LITERAL)` from the text without building what the path passes by, or the interpreter.

import "core:slice"
import core "../../core"
import engine "../../core/build"
import records "../../core/records"
import "jq"

// Why a filter is the interpreter's. `--explain` lists them in this order.
Route_Why :: enum u8 {
	Null_Input,
	Slurp,
	Sort_Keys,
	Raw_Input,
	Seq,
	Stream,
	Exit_Status,
	Raw0,
	Ascii,
	Cells_Out,
	Comments_Out, // a scan's document keeps no comments
	Not_Path,
	Dialect_Select,
	Select_Redefined,
	Select_Compare,
	Select_Path,
	Not_Columns,
	Object_Key,
	Object_Member,
	Select_Columns,
	No_Header, // a record without a header is an array
	Infer, // a cell's kind is the library's inference
	Comments_In, // a record's comment lines are written with the record
	Own_Spelling,
}

// Why the scan left a text to the interpreter.
Fallback :: enum u8 {
	Step_Kind, // a step met a value it does not apply to, where jq's rules decide
	Bad_Text, // the text does not parse, and the interpreter tells the fault
	Object_Members, // a `[]` met an object, whose repeated keys jq gives once and the scan gives each time
}

Route :: struct {
	scanning: bool,
	path:     core.Path,
	// select(PATH op LITERAL): a text prints whole when its answer compares so. `op` is `.None` for any other filter.
	select:   struct {
		op:      jq.Op,
		literal: jq.Value,
	},
	whys:     bit_set[Route_Why],
	columns:  ^Columns, // a delimited input's filter that reads only columns
	using explain: Explain,
}

// Chooses the route of the filter `text`, which `ready_interpreter` has checked. Under `--explain` every reason the
// filter is the interpreter's is found, else the first ends the search.
choose_route :: proc(run: ^Run, text: string) {
	o := &run.opts
	r := &run.route
	if reads_cells(o) {
		choose_columns(run)
		return
	}
	stops: bit_set[Route_Why]
	if o.null_input {stops += {.Null_Input}}
	if o.slurp {stops += {.Slurp}}
	if o.sort_keys {stops += {.Sort_Keys}}
	if o.raw_input {stops += {.Raw_Input}}
	if o.seq {stops += {.Seq}}
	if o.stream {stops += {.Stream}}
	if o.exit_status {stops += {.Exit_Status}}
	if o.raw0 {stops += {.Raw0}}
	if o.ascii {stops += {.Ascii}}
	if writes_cells(o) {stops += {.Cells_Out}}
	if writes_comments(o) {stops += {.Comments_Out}}
	if FORMATS[o.from].spec == .Json5 {stops += {.Own_Spelling}}
	r.whys = stops
	if stops != {} && !r.on {
		return
	}
	path, perr := core.parse_path(text)
	if perr == nil && !slice.any_of_proc(path.steps, is_unscanned) {
		r.scanning = stops == {}
		r.path = path
		return
	}
	r.whys += {.Not_Path} if perr == nil else selected_path(run, text)
	// `select` under JSONC or JSON5 is the interpreter's.
	if FORMATS[o.from].spec != .Json {
		r.whys += {.Dialect_Select}
	}
	r.scanning = r.whys == {}
}

// Whether the scan answers step `s` other than jq: a slice is one array in jq, and `..` comes in another order.
@(private = "file")
is_unscanned :: proc(s: core.Step) -> bool {
	#partial switch _ in s {
	case core.Slice, core.Descend:
		return true
	}
	return false
}

// Sets `run.route`'s path and select when the filter `text` is `select(P op LITERAL)`, P a path of names and indexes
// and LITERAL no array or object, else returns why not.
@(private = "file")
selected_path :: proc(run: ^Run, text: string) -> bit_set[Route_Why] {
	n := run.prog
	if n.kind != .Call || n.name != "select" || len(n.args) != 1 {
		return {.Not_Path}
	}
	if b, bound := n.native.?; !bound || b.native != jq.native_select {
		return {.Select_Redefined}
	}
	cmp := n.args[0]
	if cmp.kind != .Binary || cmp.op < .Eq || cmp.op > .Ge || cmp.b.kind != .Literal {
		return {.Select_Compare}
	}
	if k := jq.kind(cmp.b.value); k == .Array || k == .Object {
		return {.Select_Compare}
	}
	for x := cmp.a; x.kind != .Identity; x = x.a {
		if x.kind != .Field && x.kind != .Index || x.opt {
			return {.Select_Path}
		}
	}
	path, perr := core.parse_path(text[cmp.a.loc.start:cmp.a.loc.end])
	if perr != nil || path.limit != nil || len(path.steps) == 0 {
		return {.Select_Path}
	}
	run.route.path = path
	run.route.select = {cmp.op, cmp.b.value}
	return {}
}

// Answers the scanned filter over the text `data` and prints its outputs, as `run_once` would. Returns false, with
// nothing printed, when the text is the interpreter's: it does not parse, a step of the path meets a value it does not
// apply to, or a `[]` meets an object, whose repeated keys jq gives once and the scan gives each time.
answer_path :: proc(run: ^Run, data: []byte, r: core.As) -> bool {
	route := &run.route
	doc: core.Document
	answers: []core.Answer
	root := [1]core.Answer{{node = core.ROOT, outcome = .Found}}
	err: core.Error
	if !scans(route.path) {
		fault: Maybe(core.Fault)
		if doc, fault = jq.build_text(data, r, context.temp_allocator); fault != nil {
			err = core.error_of(fault)
		} else if len(route.path.steps) == 0 && route.path.limit == nil {
			answers = root[:] // `.`
		} else {
			perr: core.Path_Error
			answers, perr = engine.query(&doc, []core.Path{route.path}, allocator = context.temp_allocator)
			err = core.error_of(perr)
		}
	} else {
		doc, err = engine.scan(data, r, route.path, allocator = context.temp_allocator)
	}
	return answer(run, &doc, answers if answers != nil else doc.answers, err, data, r)
}

// Answers the scanned filter over the record `rec`, as `answer_path` does a text: from `part`, the path's read of it
// that ended with `read`, when `scanned`. A record that opens with a byte order mark past the input's first byte is the
// interpreter's, since a build of its text alone passes over the mark that the record's own build judges.
answer_record :: proc(run: ^Run, rec: records.Record, part: ^core.Document, read: core.Error, scanned: bool, r: core.As) -> bool {
	if scanned {
		return answer(run, part, part.answers, read, rec.text, r)
	}
	if rec.at > 0 && core.text_start(rec.text, 0) > 0 {
		explain_fallback(&run.route, .Bad_Text)
		return false
	}
	return answer_path(run, rec.text, r)
}

// Whether a scan answers `path`. When its steps are all `[]`, every value the text holds may answer, and a whole build
// costs less than a scan that keeps them all.
scans :: proc(path: core.Path) -> bool {
	return slice.any_of_proc(path.steps, proc(s: core.Step) -> bool {_, every := s.(core.All);return !every})
}

// Prints the outputs of the scanned filter from `answers` of `doc`, which the path read of the text `data` gave with
// `err`. Returns false, with nothing printed, when the text is the interpreter's.
answer :: proc(run: ^Run, doc: ^core.Document, answers: []core.Answer, err: core.Error, data: []byte, r: core.As) -> bool {
	// What a text builds lives in the temp arena and is emptied after it, so a run over many texts holds one text's at a
	// time.
	defer free_all(context.temp_allocator)
	route := &run.route
	switch {
	case err != nil:
		explain_fallback(route, .Bad_Text)
		return false
	case slice.any_of_proc(answers, proc(a: core.Answer) -> bool {return a.outcome == .Wrong_Kind}):
		explain_fallback(route, .Step_Kind)
		return false
	case iterates_object(doc, core.ROOT, route.path.steps):
		explain_fallback(route, .Object_Members)
		return false
	}
	sel := route.select
	eq := sel.op == .Eq || sel.op == .Ne
	for a in answers {
		value: jq.Value
		if a.outcome == .Found {
			value = jq.Ref{doc, a.node}
		}
		if sel.op == .None {
			emit(&run.output, value) or_return
			continue
		}
		// A container is above every literal the filter may hold.
		c := 1
		if a.outcome != .Found || doc.nodes[a.node].kind < .Array {
			c = jq.compare(jq.scalar(value), sel.literal, eq = eq)
		}
		if jq.compared(sel.op, c) {
			whole, _ := jq.build_text(data, r, context.temp_allocator)
			defer core.destroy(&whole)
			emit(&run.output, jq.Ref{&whole, core.ROOT}) or_return
		}
	}
	finish_input(&run.output)
	route.scanned += 1
	return true
}

// Whether a `[]` of `steps` meets an object in the partial document `doc` from node `i` on.
@(private = "file")
iterates_object :: proc(doc: ^core.Document, i: core.Node_Index, steps: []core.Step) -> bool {
	// A limit of 0 reads no node.
	if len(steps) == 0 || int(i) >= len(doc.nodes) {
		return false
	}
	if _, every := steps[0].(core.All); every && doc.nodes[i].kind == .Object {
		return true
	}
	it := core.children(doc, i)
	for c in core.child_next(&it) {
		if iterates_object(doc, c, steps[1:]) {
			return true
		}
	}
	return false
}
