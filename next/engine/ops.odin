package engine

import "core:io"
import "stury:cbor"
import "stury:dsv"
import "stury:html"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"
import "stury:lib/query"
import schema_check "stury:lib/schema/check"
import "stury:msgpack"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

// Runtime-dispatched universal operations over any registered format spec or runtime handle:
// validate, build, find, scan, records, write, format conversion, schema check, diff, edit commit, and reconcile.

Format_Error :: union {
	tape.Error,
	ops_write.Error,
}

Diff_Error :: union {
	tape.Error,
	diff.Error,
}

// Validates `src` against `spec` using `reads_of(spec).validate`.
@(require_results)
validate :: proc(src: []u8, spec: Spec, opts := tape.Options{}, allocator := context.allocator) -> tape.Error {
	e, ok := entry_of_spec(spec)
	if !ok {
		return tape.Bad_Option{"spec"}
	}
	return e.reads.validate(e.format, src, opts, allocator)
}

// Builds a full `tape.Document` from `src` under `spec`.
@(require_results)
build :: proc(src: []u8, spec: Spec, opts := tape.Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	e, ok := entry_of_spec(spec)
	if !ok {
		return {}, tape.Bad_Option{"spec"}
	}
	return e.reads.build(e.format, src, opts, allocator)
}

// Answers single `path` in `src` under `spec` without building a document.
@(require_results)
find :: proc(src: []u8, path: []tape.Step, spec: Spec, read := tape.Read_Options{}, opts := tape.Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	e, ok := entry_of_spec(spec)
	if !ok {
		return {}, tape.Bad_Option{"spec"}
	}
	return e.reads.find(e.format, src, path, read, opts, allocator)
}

// Builds a partial `tape.Document` containing only nodes reached by `demand`.
@(require_results)
scan :: proc(src: []u8, demand: ^tape.Demand, spec: Spec, read := tape.Read_Options{}, opts := tape.Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	e, ok := entry_of_spec(spec)
	if !ok {
		return {}, tape.Bad_Option{"spec"}
	}
	return e.reads.scan(e.format, src, demand, read, opts, allocator)
}

// Opens a framed record stream over `src` under `spec`, returning `^tape.Records` allocated in `allocator`.
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

// Writes `doc` as `to` into a newly allocated buffer owned by the caller.
@(require_results)
write :: proc(doc: ^tape.Document, to: Spec, opts := ops_write.Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: ops_write.Error) {
	switch target in to {
	case json.Spec:
		return json.write(doc, target, opts, allocator)
	case toml.Spec:
		return toml.write(doc, target, opts, allocator)
	case xml.Spec:
		return xml.write(doc, target, opts, allocator)
	case dsv.Spec:
		return dsv.write(doc, target, opts, allocator)
	case cbor.Spec:
		return cbor.write(doc, target, opts, allocator)
	case yaml.Spec:
		return yaml.write(doc, target, opts, allocator)
	case html.Spec:
		return html.write(doc, target, opts, allocator)
	case msgpack.Spec:
		return msgpack.write(doc, target, opts, allocator)
	case nil:
	}
	return nil, {}, tape.Bad_Option{"to"}
}

// Streams `doc` formatted as `to` into `sink`.
@(require_results)
write_to :: proc(sink: io.Writer, doc: ^tape.Document, to: Spec, opts := ops_write.Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: ops_write.Error) {
	switch target in to {
	case json.Spec:
		return json.write_to(sink, doc, target, opts, allocator)
	case toml.Spec:
		return toml.write_to(sink, doc, target, opts, allocator)
	case xml.Spec:
		return xml.write_to(sink, doc, target, opts, allocator)
	case dsv.Spec:
		return dsv.write_to(sink, doc, target, opts, allocator)
	case cbor.Spec:
		return cbor.write_to(sink, doc, target, opts, allocator)
	case yaml.Spec:
		return yaml.write_to(sink, doc, target, opts, allocator)
	case html.Spec:
		return html.write_to(sink, doc, target, opts, allocator)
	case msgpack.Spec:
		return msgpack.write_to(sink, doc, target, opts, allocator)
	case nil:
	}
	return {}, tape.Bad_Option{"to"}
}

// Output-only plain-text aligned table and GitHub-Flavored Markdown writers over any `tape.Document`.
write_table :: ops_write.write_table
write_table_to :: ops_write.write_table_to
write_markdown :: ops_write.write_markdown
write_markdown_to :: ops_write.write_markdown_to

// Reads `src` in `from` format and writes it in `to` format into a newly allocated buffer.
// Returns `dropped` indicating fact kinds held by the parsed document that `to` could not emit.
@(require_results)
format :: proc(src: []u8, from, to: Spec, read := tape.Options{}, opts := ops_write.Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Format_Error) {
	if from == nil {
		return nil, {}, tape.Error(tape.Bad_Option{"from"})
	}
	if to == nil {
		return nil, {}, ops_write.Error(tape.Bad_Option{"to"})
	}
	doc, rerr := build(src, from, read, allocator)
	if rerr != nil {
		return nil, {}, rerr
	}
	defer tape.destroy(&doc)
	wtext, wdropped, werr := write(&doc, to, opts, allocator)
	if werr != nil {
		return nil, {}, werr
	}
	return wtext, wdropped, nil
}

// Reads `src` in `from` format and streams it in `to` format into `sink`.
@(require_results)
format_to :: proc(sink: io.Writer, src: []u8, from, to: Spec, read := tape.Options{}, opts := ops_write.Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Format_Error) {
	if from == nil {
		return {}, tape.Error(tape.Bad_Option{"from"})
	}
	if to == nil {
		return {}, ops_write.Error(tape.Bad_Option{"to"})
	}
	doc, rerr := build(src, from, read, allocator)
	if rerr != nil {
		return {}, rerr
	}
	defer tape.destroy(&doc)
	wdropped, werr := write_to(sink, &doc, to, opts, allocator)
	if werr != nil {
		return {}, werr
	}
	return wdropped, nil
}

// Streaming format schema validation directly over `src` under `spec`.
@(require_results)
check_schema :: proc(src: []u8, spec: Spec, plan: ^schema_check.Plan, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator, dsv_opts := tape.Dsv_Options{}, yaml_opts := tape.Yaml_Options{}) -> schema_check.Result {
	switch s in spec {
	case json.Spec:
		return json.check(src, plan, s, opts, sink, allocator)
	case toml.Spec:
		return toml.check(src, plan, s, opts, sink, allocator)
	case xml.Spec:
		return xml.check(src, plan, s, opts, sink, allocator)
	case dsv.Spec:
		return dsv.check(src, plan, s, opts, sink, allocator, dsv_opts)
	case cbor.Spec:
		return cbor.check(src, plan, s, opts, sink, allocator)
	case yaml.Spec:
		return yaml.check(src, plan, s, opts, sink, allocator, yaml_opts)
	case html.Spec:
		return html.check(src, plan, s, opts, sink, allocator)
	case msgpack.Spec:
		return msgpack.check(src, plan, s, opts, sink, allocator)
	case nil:
	}
	return {valid = false, err = {kind = .Bad_Option, keyword = "spec"}}
}

// Schema check against an already-built `tape.Document`.
@(require_results)
check_document :: proc(doc: ^tape.Document, plan: ^schema_check.Plan, opts := schema_check.Options{}, sink: ^schema_check.Sink = nil, allocator := context.allocator) -> schema_check.Result {
	return schema_check.check_document(doc, plan, opts, sink, allocator)
}

// Computes structural diff between two built documents of any formats.
@(require_results)
diff_documents :: proc(a, b: ^tape.Document, opts := diff.Options{}, allocator := context.allocator) -> (diff.Result, diff.Error) {
	return diff.diff_documents(a, b, opts, allocator)
}

// Parses two byte inputs in their respective specs and computes their structural diff.
// The returned `diff.Result` owns all paths and fact strings in its own arena.
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
) -> (
	res: diff.Result,
	err: Diff_Error,
) {
	doc_a, err_a := build(src_a, spec_a, read_a, allocator)
	if err_a != nil {
		return {}, err_a
	}
	defer tape.destroy(&doc_a)

	doc_b, err_b := build(src_b, spec_b, read_b, allocator)
	if err_b != nil {
		return {}, err_b
	}
	defer tape.destroy(&doc_b)

	dres, derr := diff.diff_documents(&doc_a, &doc_b, opts, allocator)
	if derr != nil {
		return {}, derr
	}
	return dres, nil
}

@(private = "file")
resolve_edit_target :: proc "contextless" (ov: ^edit.Overlay, target: Spec, opts: edit.Options) -> (resolved: Spec, eff_opts: edit.Options, ok: bool) {
	eff_opts = opts
	if target != nil {
		tgt_fmt := format_of(target)
		if tgt_fmt == nil {
			return nil, eff_opts, false
		}
		if eff_opts.target != nil {
			if eff_opts.target != tgt_fmt {
				return nil, eff_opts, false
			}
		} else {
			eff_opts.target = tgt_fmt
		}
		return target, eff_opts, true
	}
	if opts.target != nil {
		if s, found := spec_of(opts.target); found {
			return s, eff_opts, true
		}
		return nil, eff_opts, false
	}
	if ov != nil && ov.base != nil && ov.base.format != nil {
		if s, found := spec_of(ov.base.format); found {
			eff_opts.target = ov.base.format
			return s, eff_opts, true
		}
	}
	return nil, eff_opts, false
}

// Initializes an overlay over `doc` for format-preserving edits.
edit_init :: edit.init

// Commits edits in `ov` to bytes in the resolved target format.
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
	case json.Spec:
		return json.commit(ov, s, eff_opts, allocator)
	case toml.Spec:
		return toml.commit(ov, s, eff_opts, allocator)
	case xml.Spec:
		return xml.commit(ov, eff_opts, allocator)
	case dsv.Spec:
		return dsv.commit(ov, s, eff_opts, allocator)
	case cbor.Spec:
		return cbor.commit(ov, s, eff_opts, allocator)
	case yaml.Spec:
		return yaml.commit(ov, s, eff_opts, allocator, yaml_opts)
	case html.Spec:
		return html.commit(ov, eff_opts, allocator)
	case msgpack.Spec:
		return msgpack.commit(ov, s, eff_opts, allocator)
	case nil:
	}
	return {}, tape.Bad_Option{"target"}
}

// Commits edits in `ov` to bytes and incrementally splices the resulting `tape.Document`.
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
	case json.Spec:
		return json.commit_document(ov, s, eff_opts, allocator)
	case toml.Spec:
		return toml.commit_document(ov, s, eff_opts, allocator)
	case xml.Spec:
		return xml.commit_document(ov, eff_opts, allocator)
	case dsv.Spec:
		return dsv.commit_document(ov, s, eff_opts, allocator)
	case cbor.Spec:
		return cbor.commit_document(ov, s, eff_opts, allocator)
	case yaml.Spec:
		return yaml.commit_document(ov, s, eff_opts, allocator, yaml_opts)
	case html.Spec:
		return html.commit_document(ov, eff_opts, allocator)
	case msgpack.Spec:
		return msgpack.commit_document(ov, s, eff_opts, allocator)
	case nil:
	}
	return {}, {}, tape.Bad_Option{"target"}
}

// Reconciles query output `result` onto `ov` via provenance and commits to bytes.
@(require_results)
reconcile_edit :: proc(
	h: ^query.Heap,
	ov: ^edit.Overlay,
	result: query.Value,
	target: Spec = nil,
	opts := edit.Options{},
	allocator := context.allocator,
	yaml_opts := tape.Yaml_Options{},
) -> (
	res: edit.Commit_Result,
	err: edit.Error,
) {
	query.reconcile_overlay(h, ov, result) or_return
	return edit_commit(ov, target, opts, allocator, yaml_opts)
}

// Reconciles query output `result` onto `ov` via provenance and commits a spliced `tape.Document`.
@(require_results)
reconcile_edit_document :: proc(
	h: ^query.Heap,
	ov: ^edit.Overlay,
	result: query.Value,
	target: Spec = nil,
	opts := edit.Options{},
	allocator := context.allocator,
	yaml_opts := tape.Yaml_Options{},
) -> (
	doc: tape.Document,
	res: edit.Commit_Result,
	err: edit.Error,
) {
	query.reconcile_overlay(h, ov, result) or_return
	return edit_commit_document(ov, target, opts, allocator, yaml_opts)
}
