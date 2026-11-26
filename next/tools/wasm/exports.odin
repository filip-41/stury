// Exported calls of every read that `make lint` builds for WebAssembly, so the object contains each spec's walk.
package wasm_exports

import "base:runtime"
import "core:c"
import "core:mem"
import "stury:capi"
import "stury:cbor"
import "stury:dsv"
import "stury:engine"
import "stury:jq"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import "stury:lib/ops/write"
import "stury:lib/query"
import schema_check "stury:lib/schema/check"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import schema_pkg "stury:lib/schema/schema"
import "stury:stury"
import "stury:toml"
import "stury:xml"

// Every tolerance and a step budget, which a walk with `LAX` counts, so the object holds those walks too.
TOLERANT :: json.Options{tolerate = {.Invalid_Utf8, .Non_Finite, .Lone_Surrogate}, budget = {steps = 1 << 40}}

PATH := [?]tape.Step{tape.Name("a"), tape.Index(0)}

validate_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> bool {
	return json.validate(src, S, opts) == nil
}

build_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> int {
	doc, err := json.build(src, S, opts)
	defer tape.destroy(&doc)
	return len(doc.nodes) if err == nil else -1
}

find_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> u64 {
	answer, err := json.find(src, PATH[:], S, opts = opts)
	return answer.lo if err == nil else max(u64)
}

scan_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> int {
	paths := [][]tape.Step{PATH[:]}
	demand, derr := tape.demand_of(paths)
	if derr != nil {
		return -1
	}
	defer tape.destroy_demand(&demand)
	doc, err := json.scan(src, &demand, S, opts = opts)
	defer tape.destroy(&doc)
	return len(doc.nodes) if err == nil else -1
}

// A value of any shape, which a typed read takes from any text.
Value :: union {
	bool,
	f64,
	string,
	[dynamic]Value,
	map[string]Value,
}

unmarshal_spec :: proc(src: []u8, $S: json.Spec, opts := json.Options{}) -> bool {
	// The arena is on the heap, as the compiler takes the read's error for a reference to what it allocated.
	arena := new(mem.Dynamic_Arena)
	defer free(arena)
	mem.dynamic_arena_init(arena, context.allocator, context.allocator)
	defer mem.dynamic_arena_destroy(arena)
	v: Value
	return json.unmarshal(src, &v, S, opts = opts, allocator = mem.dynamic_arena_allocator(arena)) == nil
}

@(export)
validate_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json)
}

@(export)
validate_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Jsonc)
}

@(export)
validate_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json5)
}

@(export)
build_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json)
}

@(export)
build_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Jsonc)
}

@(export)
build_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json5)
}

@(export)
find_json :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json)
}

@(export)
find_jsonc :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Jsonc)
}

@(export)
find_json5 :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json5)
}

@(export)
scan_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json)
}

@(export)
scan_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Jsonc)
}

@(export)
scan_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json5)
}

@(export)
validate_tolerant_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json, TOLERANT)
}

@(export)
validate_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
validate_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return validate_spec(p[:n], .Json5, TOLERANT)
}

@(export)
build_tolerant_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json, TOLERANT)
}

@(export)
build_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
build_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return build_spec(p[:n], .Json5, TOLERANT)
}

@(export)
find_tolerant_json :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json, TOLERANT)
}

@(export)
find_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
find_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> u64 {
	context = runtime.default_context()
	return find_spec(p[:n], .Json5, TOLERANT)
}

@(export)
scan_tolerant_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json, TOLERANT)
}

@(export)
scan_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
scan_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	return scan_spec(p[:n], .Json5, TOLERANT)
}

@(export)
unmarshal_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json)
}

@(export)
unmarshal_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Jsonc)
}

@(export)
unmarshal_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json5)
}

@(export)
unmarshal_tolerant_json :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json, TOLERANT)
}

@(export)
unmarshal_tolerant_jsonc :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Jsonc, TOLERANT)
}

@(export)
unmarshal_tolerant_json5 :: proc "c" (p: [^]u8, n: int) -> bool {
	context = runtime.default_context()
	return unmarshal_spec(p[:n], .Json5, TOLERANT)
}

// Whether an ECMA pattern matches a text, -1 for a pattern or a search that fails, so the object holds the regex
// engine.
@(export)
regex_matches :: proc "c" (pattern: [^]u8, n: int, text: [^]u8, m: int) -> int {
	context = runtime.default_context()
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	re, err := regex.compile(string(pattern[:n]), .Ecma, {}, allocator, allocator)
	if err.kind != .None {
		return -1
	}
	scratch, scratch_err := regex.scratch_make(allocator)
	if scratch_err.kind != .None {
		return -1
	}
	found, search_err := regex.search(&re, string(text[:m]), 0, nil, &scratch)
	return -1 if search_err.kind != .None else int(found)
}

@(export)
query_digest_len :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	v, s := query.digest_hex(&h, string(p[:n]), .Sha256)
	if s != .Ok {
		return -1
	}
	defer query.release(&h, v)
	return len(query.text_of(v))
}

@(export)
css_select_count :: proc "c" (sel_p: [^]u8, sel_n: int, doc_p: [^]u8, doc_n: int) -> int {
	context = runtime.default_context()
	sel, err := css.compile(string(sel_p[:sel_n]), context.allocator)
	if err != nil {
		return -1
	}
	defer css.destroy(&sel)
	doc, derr := json.build(doc_p[:doc_n], .Json, {}, context.allocator)
	if derr != nil {
		return -1
	}
	defer tape.destroy(&doc)
	found, serr := css.select(&doc, tape.ROOT, &sel, {}, context.allocator)
	if serr != nil {
		return -1
	}
	defer css.destroy_found(&found)
	return len(found.matches)
}

@(export)
jq_eval_count :: proc "c" (prog_p: [^]u8, prog_n: int, in_p: [^]u8, in_n: int) -> int {
	context = runtime.default_context()
	prog, errors := jq.compile(string(prog_p[:prog_n]))
	defer jq.destroy_program(prog)
	if len(errors) > 0 {
		return -1
	}
	doc, derr := json.build(in_p[:in_n], .Json, {}, context.allocator)
	if derr != nil {
		return -1
	}
	defer tape.destroy(&doc)
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	input, s := query.document_value(&h, doc, false)
	if s != .Ok {
		return -1
	}
	count := 0
	sink :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
		(^int)(data)^ += 1
		query.release(h, v)
		return true
	}
	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	end := jq.run_value(&run, input, sink, &count)
	return count if end == .Done else -1
}

@(export)
build_dsv :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	doc, err := dsv.build(p[:n], .Csv)
	defer tape.destroy(&doc)
	return len(doc.nodes) if err == nil else -1
}

@(export)
build_cbor :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	doc, err := cbor.build(p[:n], .Cbor)
	defer tape.destroy(&doc)
	return len(doc.nodes) if err == nil else -1
}

@(export)
build_toml :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	doc, err := toml.build(p[:n], .Toml_1_0)
	defer tape.destroy(&doc)
	return len(doc.nodes) if err == nil else -1
}

@(export)
build_xml :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	doc, err := xml.build(p[:n], .Xml)
	defer tape.destroy(&doc)
	return len(doc.nodes) if err == nil else -1
}

@(export)
format_json_to_cbor :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	out, _, err := stury.format(p[:n], json.Spec.Json, cbor.Spec.Cbor)
	defer delete(out)
	return len(out) if err == nil else -1
}

// Phase 2: overlay editing (`stury:lib/ops/edit`), commit, and incremental `commit_document`.
@(export)
edit_commit_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	doc, derr := json.build(p[:n], .Json)
	if derr != nil {
		return -1
	}
	defer tape.destroy(&doc)

	ov: edit.Overlay
	if ierr := edit.init(&ov, &doc); ierr != nil {
		return -1
	}
	defer edit.destroy(&ov)

	steps := [?]tape.Step{tape.Name("a")}
	if _, serr := edit.set_path(&ov, steps[:], edit.val_int(42)); serr != nil {
		return -1
	}
	cres, cerr := json.commit(&ov, .Json)
	if cerr != nil {
		return -1
	}
	defer edit.destroy_commit_result(&cres)

	spliced, cres2, cerr2 := json.commit_document(&ov, .Json)
	if cerr2 != nil {
		return -1
	}
	defer tape.destroy(&spliced)
	defer edit.destroy_commit_result(&cres2)
	return len(cres.bytes) + len(spliced.nodes)
}

// Phase 2: structural diff (`stury:lib/ops/diff`).
@(export)
diff_json_docs :: proc "c" (ap: [^]u8, an: int, bp: [^]u8, bn: int) -> int {
	context = runtime.default_context()
	a, aerr := json.build(ap[:an], .Json)
	if aerr != nil {
		return -1
	}
	defer tape.destroy(&a)
	b, berr := json.build(bp[:bn], .Json)
	if berr != nil {
		return -1
	}
	defer tape.destroy(&b)
	res, derr := diff.diff_documents(&a, &b)
	if derr != nil {
		return -1
	}
	defer diff.destroy_result(&res)
	return len(res.changes)
}

// Phase 2: schema rules (`stury:lib/schema/rules`).
@(export)
rules_format_valid :: proc "c" (fmt_p: [^]u8, fmt_n: int, val_p: [^]u8, val_n: int) -> bool {
	context = runtime.default_context()
	f := rules.format_of(string(fmt_p[:fmt_n]))
	return rules.format_valid(f, string(val_p[:val_n]))
}

// Phase 2: schema compile, infer, sample, and check (`stury:lib/schema/{schema,check}`).
@(export)
schema_compile_check_infer_sample :: proc "c" (sc_p: [^]u8, sc_n: int, doc_p: [^]u8, doc_n: int) -> int {
	context = runtime.default_context()
	compiled, serr := schema_pkg.compile_json(sc_p[:sc_n])
	if serr.kind != .None {
		schema_pkg.error_destroy(&serr)
		return -1
	}
	defer schema_pkg.destroy(compiled)

	doc, derr := json.build(doc_p[:doc_n], .Json)
	if derr != nil {
		return -1
	}
	defer tape.destroy(&doc)

	chk := schema_check.check_document(&doc, &compiled.plan)
	defer schema_check.result_destroy(&chk)

	inf: schema_pkg.Inferred
	defer schema_pkg.inferred_destroy(&inf)
	if ierr := schema_pkg.infer_document(&inf, &doc); ierr != nil {
		return -1
	}
	desc, desc_err := schema_pkg.inferred(&inf)
	if desc_err != nil {
		return -1
	}
	defer rules.description_destroy(&desc)

	samples, samp_err := schema_pkg.sample(&desc, {count = 1})
	if samp_err.kind != .None {
		schema_pkg.error_destroy(&samp_err)
		return -1
	}
	total := len(samples)
	for s in samples {
		delete(s)
	}
	delete(samples)
	return total + (1 if chk.valid else 0)
}

// Phase 2: typed data model load + dump (`stury:lib/schema/model`).
Wasm_Model_Record :: struct {
	name: string `json:"name"`,
	age:  int    `json:"age"`,
}

@(private = "file")
wasm_json_write_proc :: proc(doc: ^tape.Document, opts: write.Options, allocator: runtime.Allocator) -> ([]u8, tape.Facts, write.Error) {
	return json.write(doc, .Json, opts, allocator)
}

@(export)
model_load_dump_json :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	m, cerr := model.compile(nil, Wasm_Model_Record)
	if cerr != nil {
		model.error_destroy(cerr)
		return -1
	}
	defer model.destroy(&m)

	entry, ok := engine.entry_of_id(.Json)
	if !ok {
		return -1
	}
	rec: Wasm_Model_Record
	if lerr := model.load(&m, p[:n], entry.format, entry.reads, &rec); lerr != nil {
		model.error_destroy(lerr)
		return -1
	}
	defer delete(rec.name)

	dumped, derr := model.dump(&m, &rec, wasm_json_write_proc)
	if derr != nil {
		model.error_destroy(derr)
		return -1
	}
	defer delete(dumped)
	return len(dumped)
}

// Phase 3: RFC 9535 JSONPath (`stury:jsonpath`).
@(export)
jsonpath_eval_count :: proc "c" (qp: [^]u8, qn: int, doc_p: [^]u8, doc_n: int) -> int {
	context = runtime.default_context()
	prog, cerr := jsonpath.compile(string(qp[:qn]))
	if cerr.kind != .None {
		return -1
	}
	defer jsonpath.destroy_program(prog)

	doc, derr := json.build(doc_p[:doc_n], .Json)
	if derr != nil {
		return -1
	}
	defer tape.destroy(&doc)
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	root, status := query.document_value(&h, doc, false)
	if status != .Ok {
		return -1
	}
	defer query.release(&h, root)

	Ctx :: struct {
		h:     ^query.Heap,
		count: int,
	}
	ctx := Ctx{h = &h}
	emit :: proc(data: rawptr, v: query.Value, _: string) -> bool {
		c := (^Ctx)(data)
		c.count += 1
		query.release(c.h, v)
		return true
	}
	end := jsonpath.eval(prog, &h, root, emit, &ctx, {want_paths = true})
	return ctx.count if end == .Done else -1
}

// Phase 3: universal engine routing, execution, validate, build, write, and format (`stury:engine`).
@(export)
engine_surface :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	src := p[:n]
	if verr := engine.validate(src, json.Spec.Json); verr != nil {
		return -1
	}
	doc, berr := engine.build(src, json.Spec.Json)
	if berr != nil {
		return -1
	}
	defer tape.destroy(&doc)

	written, _, werr := engine.write(&doc, toml.Spec.Toml_1_0)
	if werr != nil {
		return -1
	}
	defer delete(written)

	formatted, _, ferr := engine.format(src, json.Spec.Json, cbor.Spec.Cbor)
	if ferr != nil {
		return -1
	}
	defer delete(formatted)

	plan := query.Plan{}
	dec := engine.decide(&plan, json.Spec.Json, .Single, {input_bytes = len(src)})
	eval_cb :: proc(_: rawptr, d: ^tape.Document, _: engine.Record_Meta, emit: engine.Emitter) -> engine.Exec_Error {
		_ = engine.emit_bytes(emit, d.src)
		return .None
	}
	eres := engine.execute(&plan, &dec, src, {eval = eval_cb})
	if eres.err != .None {
		return -1
	}
	return len(written) + len(formatted) + int(eres.emitted)
}

// Phase 3: universal facade (`stury:stury`) — jq_run, jsonpath_eval, check_schema, edit_init.
@(export)
stury_facade_surface :: proc "c" (p: [^]u8, n: int) -> int {
	context = runtime.default_context()
	src := p[:n]

	jqp, jq_errs := stury.jq_compile(".")
	defer stury.jq_destroy(jqp)
	if len(jq_errs) > 0 {
		return -1
	}
	jq_res := stury.jq_run(jqp, src, json.Spec.Json, nil)
	defer stury.jq_run_result_destroy(&jq_res)

	jpp, jp_err := stury.jsonpath_compile("$")
	defer stury.jsonpath_destroy(jpp)
	if jp_err.kind != .None {
		return -1
	}
	jp_res := stury.jsonpath_eval(jpp, src, json.Spec.Json, nil)

	sc_bytes := transmute([]u8)string(`{"type":"object"}`)
	sc, sc_err := stury.schema_compile(sc_bytes)
	if sc_err.kind != .None {
		stury.schema_error_destroy(&sc_err)
		return -1
	}
	defer stury.schema_destroy(sc)
	chk := stury.check_schema(src, json.Spec.Json, sc)
	defer stury.destroy_check_result(&chk)

	doc, berr := stury.build(src, json.Spec.Json)
	if berr != nil {
		return -1
	}
	defer stury.destroy(&doc)

	ov: stury.Overlay
	if ierr := stury.edit_init(&ov, &doc); ierr != nil {
		return -1
	}
	defer stury.edit_destroy(&ov)
	cres, cerr := stury.commit(&ov)
	if cerr != nil {
		return -1
	}
	defer stury.destroy_commit_result(&cres)

	return int(jq_res.emitted) + int(jp_res.emitted) + len(cres.bytes) + (1 if chk.valid else 0)
}

// Phase 3: C ABI (`stury:capi`) compiled into the WASM object alongside `stury`.
@(export)
capi_validate_wasm :: proc "c" (p: [^]u8, n: int) -> u32 {
	context = runtime.default_context()
	a := capi.stury_arena_new()
	defer capi.stury_arena_free(a)
	err := capi.stury_validate(a, p, c.size_t(n), u32(engine.Format_Id.Json), nil)
	return u32(err.code)
}
