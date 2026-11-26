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
import schema_pkg "stury:lib/schema/schema"

// Clean universal v2 facade over all registered formats, backed by `stury:engine`, `stury:lib/core/tape`,
// `stury:lib/ops/{write,edit,diff,css}`, `stury:lib/schema/{check,schema}`, `stury:jq`, and `stury:jsonpath`.
//
// Design invariants:
// - ONE concrete, non-generic `Document` across every format (JSON, TOML, XML, DSV, CBOR).
// - Facts belong to the document, not its format: `doc_facts`, `comments`, and `attributes` inspect any document.
// - Zero global mutable state, zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.

// Core document, format, capability, and resource types.
Document :: tape.Document
Format :: tape.Format
Facts :: tape.Facts
Fact :: tape.Fact
Fact_Kind :: tape.Fact_Kind
Caps :: tape.Caps
Cap :: tape.Cap
Budget :: tape.Budget
Budget_Kind :: tape.Budget_Kind
Options :: tape.Options
Read_Options :: tape.Read_Options
Format_Options :: tape.Format_Options
Dsv_Options :: tape.Dsv_Options
Xml_Options :: tape.Xml_Options
Duplicates :: tape.Duplicates
Tolerance :: tape.Tolerance
Tolerances :: tape.Tolerances

// Node, path, reader, and error types.
Node :: tape.Node
Node_Index :: tape.Node_Index
Kind :: tape.Kind
ROOT :: tape.ROOT
NO_NODE :: tape.NO_NODE
NO_BYTE :: tape.NO_BYTE
Step :: tape.Step
Name :: tape.Name
Index :: tape.Index
All :: tape.All
Slice :: tape.Slice
Descend :: tape.Descend
Demand :: tape.Demand
Reader :: tape.Reader
Doc_Index :: tape.Doc_Index
Presence :: tape.Presence
Span_Answer :: tape.Span_Answer
Error :: tape.Error
Fault :: tape.Fault
Fault_Kind :: tape.Fault_Kind
Exceeded :: tape.Exceeded
Bad_Option :: tape.Bad_Option

// Write, edit, diff, css, and schema types.
Write_Options :: ops_write.Options
Write_Error :: ops_write.Error
Overlay :: ops_edit.Overlay
Edit_Handle :: ops_edit.Handle
Edit_Value :: ops_edit.Edit_Value
Edit_Options :: ops_edit.Options
Edit_Error :: ops_edit.Error
Commit_Result :: ops_edit.Commit_Result
Diff_Options :: ops_diff.Options
Diff_Result :: ops_diff.Result
Diff_Change :: ops_diff.Change
Diff_Op :: ops_diff.Op
Css_Found :: ops_css.Found
Css_Match :: ops_css.Match
Css_Step :: ops_css.Step
Schema :: schema_pkg.Compiled
Schema_Options :: schema_pkg.Options
Schema_Error :: schema_pkg.Error
Check_Options :: schema_check.Options
Check_Result :: schema_check.Result
Check_Sink :: schema_check.Sink

// Universal operations dispatched over `Spec`.
validate :: engine.validate
build :: engine.build
find :: engine.find
scan :: engine.scan
records_open :: engine.records_open
write :: engine.write
write_to :: engine.write_to
diff :: engine.diff_bytes
diff_documents :: engine.diff_documents
commit :: engine.edit_commit
commit_document :: engine.edit_commit_document

// Streaming schema validation accepting either `^schema_check.Plan` or compiled `^Schema`.
check_schema :: proc {
	engine.check_schema,
	check_schema_compiled,
}

// Document schema validation accepting either `^schema_check.Plan` or compiled `^Schema`.
check_document :: proc {
	engine.check_document,
	check_document_compiled,
}

@(require_results)
check_schema_compiled :: proc(
	src: []u8,
	spec: Spec,
	compiled: ^Schema,
	opts := schema_check.Options{},
	sink: ^schema_check.Sink = nil,
	allocator := context.allocator,
	dsv_opts := tape.Dsv_Options{},
) -> schema_check.Result {
	if compiled == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "schema"}}
	}
	return engine.check_schema(src, spec, &compiled.plan, opts, sink, allocator, dsv_opts)
}

@(require_results)
check_document_compiled :: proc(
	doc: ^Document,
	compiled: ^Schema,
	opts := schema_check.Options{},
	sink: ^schema_check.Sink = nil,
	allocator := context.allocator,
) -> schema_check.Result {
	if compiled == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "schema"}}
	}
	return engine.check_document(doc, &compiled.plan, opts, sink, allocator)
}

// Overlay mutation helpers and `Edit_Value` builders (so callers need not import `stury:lib/ops/edit`).
edit_init :: ops_edit.init
edit_destroy :: ops_edit.destroy
destroy_commit_result :: ops_edit.destroy_commit_result
handle_for_base :: ops_edit.handle_for_base
ensure_root :: ops_edit.ensure_root
new_node :: ops_edit.new_node
set :: ops_edit.set
set_path :: ops_edit.set_path
del_path :: ops_edit.del_path
set_member :: ops_edit.set_member
insert_member :: ops_edit.insert_member
del_member :: ops_edit.del_member
rename_member :: ops_edit.rename_member
set_element :: ops_edit.set_element
insert_element :: ops_edit.insert_element
del_element :: ops_edit.del_element
reorder :: ops_edit.reorder
set_fact :: ops_edit.set_fact
del_fact :: ops_edit.del_fact
val_null :: ops_edit.val_null
val_bool :: ops_edit.val_bool
val_int :: ops_edit.val_int
val_float :: ops_edit.val_float
val_number_text :: ops_edit.val_number_text
val_string :: ops_edit.val_string
val_bytes :: ops_edit.val_bytes
val_raw :: ops_edit.val_raw
val_array :: ops_edit.val_array
val_object :: ops_edit.val_object
val_base_ref :: ops_edit.val_base_ref

// Lifecycle helpers.
destroy :: tape.destroy
demand_of :: tape.demand_of
destroy_diff :: ops_diff.destroy_result
destroy_css :: ops_css.destroy_found
schema_compile :: schema_pkg.compile_json
schema_compile_document :: schema_pkg.compile_document
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

// A decoded attribute on a markup node. `value` is owned when `owned_value` is true; free with `destroy_attributes`.
Attribute :: struct {
	name:        string,
	value:       string,
	owned_value: bool,
}

// Returns the cached set of fact kinds held by `doc` (or `{}` when `doc == nil`).
// Facts belong to the document, not its format.
doc_facts :: proc "contextless" (doc: ^Document) -> Facts {
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
		out[i] = {
			node = f.node,
			kind = f.kind,
			text = body,
		}
		i += 1
	}
	return out, nil
}

// Returns the decoded attributes on `node` in `doc` (empty when `doc` holds no attributes or `node` has none).
// Free the returned slice and any decoded values with `destroy_attributes`.
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
		for k in 0 ..< filled {
			if out[k].owned_value {
				delete(out[k].value, allocator)
			}
		}
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
					val = s
					owned = true
				} else if raw_data(s) == raw_data(buf) {
					cloned, cerr := strings.clone(s, allocator)
					delete(buf, allocator)
					if cerr != nil {
						return nil, cerr
					}
					val = cloned
					owned = true
				} else {
					delete(buf, allocator)
					val = s
				}
			} else {
				delete(buf, allocator)
			}
		}
		out[filled] = {
			name        = name,
			value       = val,
			owned_value = owned,
		}
		filled += 1
	}
	return out, nil
}

// Frees any decoded attribute values and the slice returned by `attributes`.
destroy_attributes :: proc(attrs: []Attribute, allocator := context.allocator) {
	for a in attrs {
		if a.owned_value {
			delete(a.value, allocator)
		}
	}
	delete(attrs, allocator)
}

// Selects markup elements matching CSS `selector` below `from` (default `ROOT`) in `doc`.
// Returns `ok = false` cleanly when `doc` is nil, does not support CSS selection (non-markup format),
// is partial, or `selector` fails to compile. Caller frees `hits` with `destroy_css(&hits)` when `ok` is true.
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
