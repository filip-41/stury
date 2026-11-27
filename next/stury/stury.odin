package stury

import "base:runtime"
import "core:strings"
import "stury:engine"
import "stury:lib/core/tape"
import ops_css "stury:lib/ops/css"
import ops_diff "stury:lib/ops/diff"
import ops_edit "stury:lib/ops/edit"
import ops_write "stury:lib/ops/write"
import schema_check "stury:lib/schema/check"
import ddl_pkg "stury:lib/schema/ddl"
import schema_pkg "stury:lib/schema/schema"

// Clean universal v2 facade over all registered formats, backed by `stury:engine`, `stury:lib/core/tape`,
// `stury:lib/ops/{write,edit,diff,css,typed}`, `stury:lib/schema/{check,ddl,schema}`, `stury:jq`, and `stury:jsonpath`.
//
// Design invariants:
// - ONE concrete, non-generic `Document` across every format (JSON, TOML, XML, DSV, CBOR, YAML, HTML, MessagePack).
// - Facts belong to the document, not its format: `doc_facts`, `comments`, and `attributes` inspect any document.
// - Per-spec dead-stripping works via direct format packages (e.g. `json.build`, `cbor.unmarshal`), whereas `stury.*`
//   routes dynamically through the `engine` registry across all registered formats.
// - Zero global mutable state, zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.

// Core document, overlay, and error types.
Document :: tape.Document
Error :: tape.Error
Write_Error :: ops_write.Error
Overlay :: ops_edit.Overlay
Edit_Error :: ops_edit.Error

// Universal operations dispatched over `Spec`.
validate :: engine.validate
build :: engine.build
find :: engine.find
scan :: engine.scan
write :: proc {
	engine.write,
	engine.write_to,
}
unmarshal :: engine.unmarshal
marshal :: proc {
	engine.marshal,
	engine.marshal_to,
}
write_table :: engine.write_table
write_markdown :: engine.write_markdown
diff :: proc {
	engine.diff_bytes,
	engine.diff_documents,
}
commit :: engine.edit_commit
commit_document :: engine.edit_commit_document

// Streaming schema validation accepting `^schema_check.Plan`, compiled `^schema.Compiled`, or compiled `^ddl.Compiled`.
check_schema :: proc {
	engine.check_schema,
	check_schema_compiled,
	check_schema_ddl,
}

// Document schema validation accepting `^schema_check.Plan`, compiled `^schema.Compiled`, or compiled `^ddl.Compiled`.
check_document :: proc {
	engine.check_document,
	check_document_compiled,
	check_document_ddl,
}

@(private = "file", require_results)
check_schema_compiled :: proc(
	src: []u8,
	spec: Spec,
	compiled: ^schema_pkg.Compiled,
	opts := schema_check.Options{},
	sink: ^schema_check.Sink = nil,
	allocator := context.allocator,
	dsv_opts := tape.Dsv_Options{},
	yaml_opts := tape.Yaml_Options{},
) -> schema_check.Result {
	if compiled == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "schema"}}
	}
	return engine.check_schema(src, spec, &compiled.plan, opts, sink, allocator, dsv_opts, yaml_opts)
}

@(private = "file", require_results)
check_document_compiled :: proc(
	doc: ^Document,
	compiled: ^schema_pkg.Compiled,
	opts := schema_check.Options{},
	sink: ^schema_check.Sink = nil,
	allocator := context.allocator,
) -> schema_check.Result {
	if compiled == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "schema"}}
	}
	return engine.check_document(doc, &compiled.plan, opts, sink, allocator)
}

@(private = "file", require_results)
check_schema_ddl :: proc(
	src: []u8,
	spec: Spec,
	compiled: ^ddl_pkg.Compiled,
	opts := schema_check.Options{},
	sink: ^schema_check.Sink = nil,
	allocator := context.allocator,
	dsv_opts := tape.Dsv_Options{},
	yaml_opts := tape.Yaml_Options{},
) -> schema_check.Result {
	if compiled == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "schema"}}
	}
	return engine.check_schema(src, spec, &compiled.plan, opts, sink, allocator, dsv_opts, yaml_opts)
}

@(private = "file", require_results)
check_document_ddl :: proc(
	doc: ^Document,
	compiled: ^ddl_pkg.Compiled,
	opts := schema_check.Options{},
	sink: ^schema_check.Sink = nil,
	allocator := context.allocator,
) -> schema_check.Result {
	if compiled == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "schema"}}
	}
	return engine.check_document(doc, &compiled.plan, opts, sink, allocator)
}

// Overlay mutation helpers (for low-level overlay operations, import `stury:lib/ops/edit` directly).
edit_init :: ops_edit.init
edit_destroy :: ops_edit.destroy
destroy_commit_result :: ops_edit.destroy_commit_result
set_path :: ops_edit.set_path
val_int :: ops_edit.val_int
val_string :: ops_edit.val_string

// Lifecycle and schema helpers.
destroy :: proc {
	tape.destroy_document,
	tape.destroy_demand,
	tape.destroy_index,
	tape.destroy_line_index,
	tape.destroy_children,
	tape.destroy_records,
	ops_css.destroy_found,
	destroy_attributes_impl,
	ddl_pkg.destroy,
}
destroy_diff :: ops_diff.destroy_result
schema_compile :: schema_pkg.compile_json
schema_compile_ddl :: ddl_pkg.compile_ddl
schema_destroy :: schema_pkg.destroy
schema_error_destroy :: schema_pkg.error_destroy
destroy_check_result :: schema_check.result_destroy

// A comment fact held by a document, attached to `node`.
// `text` borrows from `doc.src` with opening/closing comment markers and optional single-space padding stripped.
Comment :: struct {
	node: tape.Node_Index,
	kind: tape.Fact_Kind,
	text: string,
}

// A decoded attribute on a markup node. `value` is owned when `owned_value` is true; free with `destroy`.
Attribute :: struct {
	name:        string,
	value:       string,
	owned_value: bool,
}

// Returns the cached set of fact kinds held by `doc` (or `{}` when `doc == nil`).
// Facts belong to the document, not its format.
doc_facts :: proc "contextless" (doc: ^Document) -> tape.Facts {
	if doc == nil {
		return {}
	}
	return doc.present
}

// Returns every comment fact held by `doc` in source order, whatever its format (empty when `doc` holds none).
// Each `Comment.text` borrows from `doc.src`; the caller frees the returned slice with `delete(out, allocator)`.
@(require_results)
comments :: proc(doc: ^Document, allocator := context.allocator) -> (out: []Comment, err: runtime.Allocator_Error) {
	if doc == nil || doc.present & tape.COMMENTS == {} || len(doc.facts) == 0 {
		return nil, nil
	}
	count := 0
	for f in doc.facts {
		if f.kind == .Comment || f.kind == .Comment_Inline || f.kind == .Comment_Foot {
			count += 1
		}
	}
	if count == 0 {
		return nil, nil
	}
	out = make([]Comment, count, allocator) or_return
	i := 0
	for f in doc.facts {
		if f.kind != .Comment && f.kind != .Comment_Inline && f.kind != .Comment_Foot {
			continue
		}
		raw := tape.span_bytes(doc, f.lo, f.n)
		lead := min(int(tape.fact_lead(f.spelling)), len(raw))
		tail := min(int(tape.fact_tail(f.spelling)), len(raw) - lead)
		body := string(raw[lead : len(raw) - tail])
		if lead > 0 && len(body) > 0 && body[0] == ' ' {
			body = body[1:]
		}
		if tail > 0 && len(body) > 0 && body[len(body) - 1] == ' ' {
			body = body[:len(body) - 1]
		}
		out[i] = {node = f.node, kind = f.kind, text = body}
		i += 1
	}
	return out, nil
}

// Returns the decoded attributes on `node` in `doc` (empty when `doc` holds no attributes or `node` has none).
// Free the returned slice and any decoded values with `destroy(attrs, allocator)`.
@(require_results)
attributes :: proc(doc: ^Document, node: tape.Node_Index, allocator := context.allocator) -> (out: []Attribute, err: runtime.Allocator_Error) {
	if doc == nil || doc.format == nil || doc.format.attribute == nil || .Attribute not_in doc.present || node == tape.NO_NODE {
		return nil, nil
	}
	facts := tape.facts_of(doc, node)
	count := 0
	for f in facts {
		if f.kind == .Attribute {
			count += 1
		}
	}
	if count == 0 {
		return nil, nil
	}
	out = make([]Attribute, count, allocator) or_return
	filled := 0
	defer if err != nil {
		destroy_attributes_impl(out[:filled], allocator)
		delete(out, allocator)
		out = nil
	}
	for f in facts {
		if f.kind != .Attribute {
			continue
		}
		kt, vt := doc.format.attribute(doc, f)
		name := string(tape.span_bytes(doc, kt.lo, kt.n))
		room := tape.text_room(doc, vt)
		val := ""
		owned := false
		if room == 0 {
			if s, ok := tape.node_text(doc, vt, nil); ok {
				val = s
			}
		} else {
			buf := make([]u8, room, allocator) or_return
			if s, ok := tape.node_text(doc, vt, buf); ok {
				if raw_data(s) == raw_data(buf) && len(s) == len(buf) {
					val, owned = s, true
				} else if raw_data(s) == raw_data(buf) {
					cloned, cerr := strings.clone(s, allocator)
					delete(buf, allocator)
					if cerr != nil {
						return nil, cerr
					}
					val, owned = cloned, true
				} else {
					delete(buf, allocator)
					val = s
				}
			} else {
				delete(buf, allocator)
			}
		}
		out[filled] = {name = name, value = val, owned_value = owned}
		filled += 1
	}
	return out, nil
}

@(private = "file")
destroy_attributes_impl :: proc(attrs: []Attribute, allocator := context.allocator) {
	for a in attrs {
		if a.owned_value {
			delete(a.value, allocator)
		}
	}
	delete(attrs, allocator)
}

// Selects markup elements matching CSS `selector` below `from` (default `ROOT`) in `doc`.
// Returns `ok = false` cleanly when `doc` is nil, does not support CSS selection (non-markup format),
// is partial, or `selector` fails to compile. Caller frees `hits` with `destroy(&hits)` when `ok` is true.
@(require_results)
css :: proc(
	doc: ^Document,
	selector: string,
	from := tape.ROOT,
	allocator := context.allocator,
) -> (
	hits: ops_css.Found,
	ok: bool,
) {
	if doc == nil || doc.format == nil || doc.format.attribute == nil || doc.partial != nil {
		return {}, false
	}
	sel, cerr := ops_css.compile(selector, allocator)
	if cerr != nil {
		return {}, false
	}
	defer ops_css.destroy(&sel)
	found, serr := ops_css.select(doc, from, &sel, {attribute = doc.format.attribute}, allocator)
	if serr != nil {
		return {}, false
	}
	if found.partial {
		ops_css.destroy_found(&found)
		return {}, false
	}
	return found, true
}
