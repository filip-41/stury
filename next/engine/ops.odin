package engine

import "core:io"
import "stury:cbor"
import "stury:dsv"
import "stury:html"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import ops_typed "stury:lib/ops/typed"
import ops_write "stury:lib/ops/write"
import "stury:lib/query"
import schema_check "stury:lib/schema/check"
import "stury:msgpack"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

// Runtime-dispatched universal operations over any registered format spec or runtime handle.

Format_Error :: union {
	tape.Error,
	ops_write.Error,
}

Diff_Error :: union {
	tape.Error,
	diff.Error,
}

// Re-exports of core op types/helpers so thin shells (`cli`, `stury`) do not import `lib/ops/*` or `lib/schema/check` directly.
Write_Options :: ops_write.Options
Write_Error :: ops_write.Error
Write_Refused :: ops_write.Refused
Write_Refusal :: ops_write.Refusal
Write_Record_Framing :: ops_write.Record_Framing
Write_Token_Tape :: ops_write.Token_Tape
Write_Token_Kind :: ops_write.Token_Kind
Write_Table_Writer :: ops_write.Table_Writer
Write_Cells :: ops_write.Cells
Table_Render_Options :: ops_write.Table_Render_Options
Markdown_Options :: ops_write.Markdown_Options
WRITE_SINK_BYTES :: ops_write.SINK_BYTES

write_table :: ops_write.write_table
write_table_to :: ops_write.write_table_to
write_table_docs :: ops_write.write_table_docs
write_markdown :: ops_write.write_markdown
write_markdown_to :: ops_write.write_markdown_to
write_markdown_docs :: ops_write.write_markdown_docs
token_tape_start :: ops_write.token_tape_start
token_tape_take :: ops_write.token_tape_take
token_tape_done :: ops_write.token_tape_done
token_tape_document :: ops_write.token_tape_document
token_tape_drop :: ops_write.token_tape_drop
tokens_of :: ops_write.tokens_of
table_writer_start :: ops_write.table_writer_start
table_writer_token :: ops_write.table_writer_token
table_writer_end :: ops_write.table_writer_end
table_writer_drop :: ops_write.table_writer_drop

Diff_Arrays :: diff.Arrays
Diff_Key_Rule :: diff.Key_Rule
Diff_Options :: diff.Options
Diff_Change :: diff.Change
Diff_Op :: diff.Op
Diff_Patch :: diff.Patch
diff_to_patch :: diff.diff_to_patch
destroy_diff_result :: diff.destroy_result
destroy_diff_patch :: diff.destroy_patch

Edit_Options :: edit.Options
Edit_Error :: edit.Error
Edit_Refusal :: edit.Refusal
edit_init :: edit.init
edit_get_node_by_idx :: edit.get_node_by_idx
destroy_commit_result :: edit.destroy_commit_result

Check_Sink :: schema_check.Sink
Check_Error :: schema_check.Check_Error
Check_Result :: schema_check.Result
check_sink_init :: schema_check.sink_init
check_sink_destroy :: schema_check.sink_destroy
check_result_destroy :: schema_check.result_destroy

// CSS markup attribute hook for jq/query runtimes.
markup_hook :: proc(_: rawptr, doc: ^tape.Document) -> (css.Options, bool) {
	if doc != nil && doc.format != nil && doc.format.attribute != nil {
		return {attribute = doc.format.attribute}, true
	}
	return {}, false
}

@(require_results)
validate :: proc(src: []u8, spec: Spec, opts := tape.Options{}, allocator := context.allocator) -> tape.Error {
	e, ok := entry_of_spec(spec)
	return e.reads.validate(e.format, src, opts, allocator) if ok else tape.Bad_Option{"spec"}
}

@(require_results)
build :: proc(src: []u8, spec: Spec, opts := tape.Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	e, ok := entry_of_spec(spec)
	if !ok {
		return {}, tape.Bad_Option{"spec"}
	}
	return e.reads.build(e.format, src, opts, allocator)
}

@(require_results)
find :: proc(src: []u8, path: []tape.Step, spec: Spec, read := tape.Read_Options{}, opts := tape.Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	e, ok := entry_of_spec(spec)
	if !ok {
		return {}, tape.Bad_Option{"spec"}
	}
	return e.reads.find(e.format, src, path, read, opts, allocator)
}

@(require_results)
scan :: proc(src: []u8, demand: ^tape.Demand, spec: Spec, read := tape.Read_Options{}, opts := tape.Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	e, ok := entry_of_spec(spec)
	if !ok {
		return {}, tape.Bad_Option{"spec"}
	}
	return e.reads.scan(e.format, src, demand, read, opts, allocator)
}

@(require_results)
records_open :: proc(src: []u8, spec: Spec, framing := tape.Framing.Lines, opts := tape.Options{}, path: []tape.Step = nil, allocator := context.allocator) -> (^tape.Records, tape.Error) {
	e, ok := entry_of_spec(spec)
	if !ok {
		return nil, tape.Bad_Option{"spec"}
	}
	recs, aerr := e.reads.records(e.format, src, framing, opts, path, allocator)
	if aerr != nil {
		return nil, aerr
	}
	return recs, nil
}

@(require_results)
write :: proc(doc: ^tape.Document, to: Spec, opts := ops_write.Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: ops_write.Error) {
	switch target in to {
	case json.Spec:    return json.write(doc, target, opts, allocator)
	case toml.Spec:    return toml.write(doc, target, opts, allocator)
	case xml.Spec:     return xml.write(doc, target, opts, allocator)
	case dsv.Spec:     return dsv.write(doc, target, opts, allocator)
	case cbor.Spec:    return cbor.write(doc, target, opts, allocator)
	case yaml.Spec:    return yaml.write(doc, target, opts, allocator)
	case html.Spec:    return html.write(doc, target, opts, allocator)
	case msgpack.Spec: return msgpack.write(doc, target, opts, allocator)
	case nil:
	}
	return nil, {}, tape.Bad_Option{"to"}
}

@(require_results)
write_to :: proc(sink: io.Writer, doc: ^tape.Document, to: Spec, opts := ops_write.Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: ops_write.Error) {
	switch target in to {
	case json.Spec:    return json.write_to(sink, doc, target, opts, allocator)
	case toml.Spec:    return toml.write_to(sink, doc, target, opts, allocator)
	case xml.Spec:     return xml.write_to(sink, doc, target, opts, allocator)
	case dsv.Spec:     return dsv.write_to(sink, doc, target, opts, allocator)
	case cbor.Spec:    return cbor.write_to(sink, doc, target, opts, allocator)
	case yaml.Spec:    return yaml.write_to(sink, doc, target, opts, allocator)
	case html.Spec:    return html.write_to(sink, doc, target, opts, allocator)
	case msgpack.Spec: return msgpack.write_to(sink, doc, target, opts, allocator)
	case nil:
	}
	return {}, tape.Bad_Option{"to"}
}

@(require_results)
unmarshal :: proc(
	src: []u8,
	target: ^$T,
	spec: Spec,
	read := ops_typed.Unmarshal_Options{},
	opts := tape.Options{},
	allocator := context.allocator,
) -> tape.Error {
	switch s in spec {
	case json.Spec:    return json.unmarshal(src, target, s, read, opts, allocator)
	case toml.Spec:    return toml.unmarshal(src, target, s, read, opts, allocator)
	case xml.Spec:     return xml.unmarshal(src, target, s, read, opts, allocator)
	case dsv.Spec:     return dsv.unmarshal(src, target, s, read, opts, allocator)
	case cbor.Spec:    return cbor.unmarshal(src, target, s, read, opts, allocator)
	case yaml.Spec:    return yaml.unmarshal(src, target, s, read, opts, allocator)
	case html.Spec:    return html.unmarshal(src, target, s, read, opts, allocator)
	case msgpack.Spec: return msgpack.unmarshal(src, target, s, read, opts, allocator)
	case nil:
	}
	return tape.Bad_Option{"spec"}
}

@(require_results)
marshal :: proc(
	value: ^$T,
	to: Spec,
	opts := ops_write.Options{},
	plan: ^ops_typed.Plan = nil,
	allocator := context.allocator,
) -> (
	text: []u8,
	err: ops_write.Error,
) {
	switch s in to {
	case json.Spec:    return json.marshal(value, opts, plan, allocator)
	case toml.Spec:    return toml.marshal(value, s, opts, plan, allocator)
	case xml.Spec:     return xml.marshal(value, s, opts, plan, allocator)
	case dsv.Spec:     return dsv.marshal(value, s, opts, plan, allocator)
	case cbor.Spec:    return cbor.marshal(value, s, opts, plan, allocator)
	case yaml.Spec:    return yaml.marshal(value, s, opts, plan, allocator)
	case html.Spec:    return html.marshal(value, s, opts, plan, allocator)
	case msgpack.Spec: return msgpack.marshal(value, s, opts, plan, allocator)
	case nil:
	}
	return nil, tape.Bad_Option{"to"}
}

@(require_results)
marshal_to :: proc(
	sink: io.Writer,
	value: ^$T,
	to: Spec,
	opts := ops_write.Options{},
	plan: ^ops_typed.Plan = nil,
	allocator := context.allocator,
) -> ops_write.Error {
	switch s in to {
	case json.Spec:    return json.marshal_to(sink, value, opts, plan, allocator)
	case toml.Spec:    return toml.marshal_to(sink, value, s, opts, plan, allocator)
	case xml.Spec:     return xml.marshal_to(sink, value, s, opts, plan, allocator)
	case dsv.Spec:     return dsv.marshal_to(sink, value, s, opts, plan, allocator)
	case cbor.Spec:    return cbor.marshal_to(sink, value, s, opts, plan, allocator)
	case yaml.Spec:    return yaml.marshal_to(sink, value, s, opts, plan, allocator)
	case html.Spec:    return html.marshal_to(sink, value, s, opts, plan, allocator)
	case msgpack.Spec: return msgpack.marshal_to(sink, value, s, opts, plan, allocator)
	case nil:
	}
	return tape.Bad_Option{"to"}
}

@(require_results)
format :: proc(src: []u8, from, to: Spec, read := tape.Options{}, opts := ops_write.Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Format_Error) {
	if from == nil { return nil, {}, tape.Error(tape.Bad_Option{"from"}) }
	if to == nil { return nil, {}, ops_write.Error(tape.Bad_Option{"to"}) }
	doc, rerr := build(src, from, read, allocator)
	if rerr != nil { return nil, {}, rerr }
	defer tape.destroy(&doc)
	wtext, wdropped, werr := write(&doc, to, opts, allocator)
	if werr != nil { return nil, {}, werr }
	return wtext, wdropped, nil
}

@(require_results)
format_to :: proc(sink: io.Writer, src: []u8, from, to: Spec, read := tape.Options{}, opts := ops_write.Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Format_Error) {
	if from == nil { return {}, tape.Error(tape.Bad_Option{"from"}) }
	if to == nil { return {}, ops_write.Error(tape.Bad_Option{"to"}) }
	doc, rerr := build(src, from, read, allocator)
	if rerr != nil { return {}, rerr }
	defer tape.destroy(&doc)
	wdropped, werr := write_to(sink, &doc, to, opts, allocator)
	if werr != nil { return {}, werr }
	return wdropped, nil
}

@(require_results)
check_schema :: proc(src: []u8, spec: Spec, plan: ^schema_check.Plan, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator, dsv_opts := tape.Dsv_Options{}, yaml_opts := tape.Yaml_Options{}) -> schema_check.Result {
	switch s in spec {
	case json.Spec:    return json.check(src, plan, s, opts, sink, allocator)
	case toml.Spec:    return toml.check(src, plan, s, opts, sink, allocator)
	case xml.Spec:     return xml.check(src, plan, s, opts, sink, allocator)
	case dsv.Spec:     return dsv.check(src, plan, s, opts, sink, allocator, dsv_opts)
	case cbor.Spec:    return cbor.check(src, plan, s, opts, sink, allocator)
	case yaml.Spec:    return yaml.check(src, plan, s, opts, sink, allocator, yaml_opts)
	case html.Spec:    return html.check(src, plan, s, opts, sink, allocator)
	case msgpack.Spec: return msgpack.check(src, plan, s, opts, sink, allocator)
	case nil:
	}
	return {valid = false, err = {kind = .Bad_Option, keyword = "spec"}}
}

@(require_results)
check_document :: proc(doc: ^tape.Document, plan: ^schema_check.Plan, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator) -> schema_check.Result {
	return schema_check.check_document(doc, plan, opts, sink, allocator)
}

@(require_results)
diff_documents :: proc(a, b: ^tape.Document, opts := diff.Options{}, allocator := context.allocator) -> (diff.Result, diff.Error) {
	return diff.diff_documents(a, b, opts, allocator)
}

@(require_results)
diff_bytes :: proc(
	src_a: []u8,
	spec_a: Spec,
	src_b: []u8,
	spec_b: Spec,
	read_a := tape.Options{},
	read_b := tape.Options{},
	opts := diff.Options{},
	allocator := context.allocator,
) -> (res: diff.Result, err: Diff_Error) {
	doc_a, err_a := build(src_a, spec_a, read_a, allocator)
	if err_a != nil { return {}, err_a }
	defer tape.destroy(&doc_a)
	doc_b, err_b := build(src_b, spec_b, read_b, allocator)
	if err_b != nil { return {}, err_b }
	defer tape.destroy(&doc_b)
	dres, derr := diff.diff_documents(&doc_a, &doc_b, opts, allocator)
	if derr != nil { return {}, derr }
	return dres, nil
}

@(private = "file")
resolve_edit_target :: proc "contextless" (ov: ^edit.Overlay, target: Spec, opts: edit.Options) -> (resolved: Spec, eff_opts: edit.Options, ok: bool) {
	eff_opts = opts
	if target != nil {
		tgt_fmt := format_of(target)
		if tgt_fmt == nil || (eff_opts.target != nil && eff_opts.target != tgt_fmt) {
			return nil, eff_opts, false
		}
		eff_opts.target = tgt_fmt
		return target, eff_opts, true
	}
	if opts.target != nil {
		s, found := spec_of(opts.target)
		return s, eff_opts, found
	}
	if ov != nil && ov.base != nil && ov.base.format != nil {
		if s, found := spec_of(ov.base.format); found {
			eff_opts.target = ov.base.format
			return s, eff_opts, true
		}
	}
	return nil, eff_opts, false
}

@(require_results)
edit_commit :: proc(ov: ^edit.Overlay, target: Spec = nil, opts := edit.Options{}, allocator := context.allocator, yaml_opts := tape.Yaml_Options{}) -> (res: edit.Commit_Result, err: edit.Error) {
	if ov == nil || ov.base == nil {
		return {}, edit.refuse(.No_Document, "edit_commit requires an initialized overlay")
	}
	resolved, eff_opts, ok := resolve_edit_target(ov, target, opts)
	if !ok {
		return {}, tape.Bad_Option{"target"}
	}
	switch s in resolved {
	case json.Spec:    return json.commit(ov, s, eff_opts, allocator)
	case toml.Spec:    return toml.commit(ov, s, eff_opts, allocator)
	case xml.Spec:     return xml.commit(ov, eff_opts, allocator)
	case dsv.Spec:     return dsv.commit(ov, s, eff_opts, allocator)
	case cbor.Spec:    return cbor.commit(ov, s, eff_opts, allocator)
	case yaml.Spec:    return yaml.commit(ov, s, eff_opts, allocator, yaml_opts)
	case html.Spec:    return html.commit(ov, eff_opts, allocator)
	case msgpack.Spec: return msgpack.commit(ov, s, eff_opts, allocator)
	case nil:
	}
	return {}, tape.Bad_Option{"target"}
}

@(require_results)
edit_commit_document :: proc(ov: ^edit.Overlay, target: Spec = nil, opts := edit.Options{}, allocator := context.allocator, yaml_opts := tape.Yaml_Options{}) -> (doc: tape.Document, res: edit.Commit_Result, err: edit.Error) {
	if ov == nil || ov.base == nil {
		return {}, {}, edit.refuse(.No_Document, "edit_commit_document requires an initialized overlay")
	}
	resolved, eff_opts, ok := resolve_edit_target(ov, target, opts)
	if !ok {
		return {}, {}, tape.Bad_Option{"target"}
	}
	switch s in resolved {
	case json.Spec:    return json.commit_document(ov, s, eff_opts, allocator)
	case toml.Spec:    return toml.commit_document(ov, s, eff_opts, allocator)
	case xml.Spec:     return xml.commit_document(ov, eff_opts, allocator)
	case dsv.Spec:     return dsv.commit_document(ov, s, eff_opts, allocator)
	case cbor.Spec:    return cbor.commit_document(ov, s, eff_opts, allocator)
	case yaml.Spec:    return yaml.commit_document(ov, s, eff_opts, allocator, yaml_opts)
	case html.Spec:    return html.commit_document(ov, eff_opts, allocator)
	case msgpack.Spec: return msgpack.commit_document(ov, s, eff_opts, allocator)
	case nil:
	}
	return {}, {}, tape.Bad_Option{"target"}
}

@(require_results)
reconcile_edit :: proc(
	h: ^query.Heap,
	ov: ^edit.Overlay,
	result: query.Value,
	target: Spec = nil,
	opts := edit.Options{},
	allocator := context.allocator,
	yaml_opts := tape.Yaml_Options{},
) -> (res: edit.Commit_Result, err: edit.Error) {
	query.reconcile_overlay(h, ov, result) or_return
	return edit_commit(ov, target, opts, allocator, yaml_opts)
}

@(require_results)
reconcile_edit_document :: proc(
	h: ^query.Heap,
	ov: ^edit.Overlay,
	result: query.Value,
	target: Spec = nil,
	opts := edit.Options{},
	allocator := context.allocator,
	yaml_opts := tape.Yaml_Options{},
) -> (doc: tape.Document, res: edit.Commit_Result, err: edit.Error) {
	query.reconcile_overlay(h, ov, result) or_return
	return edit_commit_document(ov, target, opts, allocator, yaml_opts)
}
