package yaml

// The typed read of YAML: `unmarshal` reads a document into a value through the document route of `core/typed`, since
// an alias repeats its anchor's node. A field or a map key is named by a key's decoded text. Two keys of one text and
// two types are refused, except under `.First` and `.All`. A plain scalar is read as the core schema resolves it.

import "base:runtime"
import "core:slice"
import "core:strings"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import cw "../core/write"

// Reads `src`, a YAML text of one document, into `target`. An absent member keeps what `target` holds. The form with
// no plan builds one with `context.allocator` and frees it before it returns, and a plan built once with `plan_make` is
// the form for many reads. A refusal leaves everything the read allocated reachable from `target`. `read.dups` picks
// among a repeated key as `json.unmarshal` does.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Returns the typed reads of `spec`, which `plan_make` takes for a plan that reads through `typed.unmarshal_text`.
reads :: proc "contextless" (spec: Spec) -> ^typed.Format_Reads {
	return &READS
}

// Returns the checks of `spec` read with `opts`, which `model.compile` and `schema.bind` take: the reads of a plan made
// from a model or a description, and the handle of `spec` its plans read by.
checks :: proc "contextless" (spec: Spec, opts := Options{}) -> typed.Format_Checks {
	return {&CHECKS, bound_as(spec, opts)}
}

// Builds the plan of `T` for YAML, as `typed.plan_make` does. The plan reads a text only with `reads`, and with none it
// reads through `unmarshal`.
plan_make :: proc(T: typeid, spec := Spec.Yaml_1_2, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, reads, allocator)
	return made, core.error_of(err)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does. The reads are the plan's with
// `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Yaml_1_2, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := typed.plan_of(d, as_of(&PLAN_READERS, spec, {}), reads, opts, allocator)
	if err == nil {
		plan_bind(&made)
	}
	return made, err
}

// The plan of `T` with the writer, the token writer and the document read of YAML, and the reads `reads` holds.
@(private)
plan_built :: proc(T: typeid, spec: Spec, layout: Options, opts: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as_of(&PLAN_READERS, spec, layout), opts, allocator)
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, err
}

// Gives a plan YAML's writer, token writer, document read and check of a `Raw` member's text.
@(private)
plan_bind :: proc(p: ^typed.Plan) {
	p.marshal, p.tokens, p.node_read, p.raw = marshal_text, &TOKENS, node_read, edit_value
	p.value_text = cw.value_text
}

// The handle's `plans`.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as, opts, allocator)
	plan_bind(&p)
	return p, err
}

// The read of a text: its document is built, under `.Refuse` refusing a repeated key, and read as `typed.read_nodes`
// reads it.
@(private)
text_read :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return typed.read_built_text(src, as, typed_build, target, T, plan, read, allocator)
}

// The check of a text: `text_read` with every refusal in `read.sink.entries`.
@(private)
text_check :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return typed.check_built_text(src, as, typed_build, target, T, plan, read, allocator)
}

// The build of a text whose scalars hold the kinds the reader takes.
@(private)
typed_build :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_as(src, as, refuse_duplicates, allocator)
	if err.kind == .None {
		type_scalars(&doc, core.ROOT, doc.nodes)
	}
	return doc, err
}

// The read of a node of a built document, a plan's `node_read`. The document's scalars are `Plain` until `resolve`
// types them, and the reader takes a token's kind as it stands, so the node's subtree is read from a copy whose value
// scalars hold their kinds.
@(private)
node_read :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return read_node(doc, node, T, target, plan, read, allocator, false)
}

// `node_read` with every refusal in `read.sink.entries`, a plan's `node_check`.
@(private)
node_check :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return read_node(doc, node, T, target, plan, read, allocator, true)
}

@(private)
read_node :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, $CHECK: bool) -> core.Typed_Refusal {
	size := core.subtree_size(doc, node)
	nodes, failed := slice.clone(doc.nodes[node:][:size])
	if failed != nil {
		return {kind = .No_Memory}
	}
	defer delete(nodes)
	type_scalars(doc, node, nodes)
	// The reader takes the nodes, the source and the format of a document and nothing a node's index names.
	subtree := doc^
	subtree.nodes = nodes
	when CHECK {
		return typed.check_nodes(&subtree, core.ROOT, T, target, plan, read, allocator)
	} else {
		return typed.read_nodes(&subtree, core.ROOT, T, target, plan, read, allocator)
	}
}

// Gives each plain value scalar of `nodes`, the nodes of `doc` from `first` on or a copy of them, the kind the core
// schema reads it as, since the reader takes a token's kind as it stands. A number takes the spelling of its form,
// which the reader reads it by. A quoted or block scalar a tag makes a number becomes the number its bytes spell between
// the quotes or past the header, and one whose text is not a run of its bytes, as an escaped digit, keeps its kind.
@(private)
type_scalars :: proc(doc: ^core.Document, first: core.Node_Index, nodes: []core.Node) {
	for &n, i in nodes {
		if n.kind != .Plain || n.role != .Value {
			continue
		}
		k := spelling_resolve(doc, first + core.Node_Index(i))
		if k == .Number {
			span := doc.src[n.lo:n.lo + u64(n.n)]
			if n.spelling & core.SPELLING_DECODE != 0 || style_of(n.spelling) != .Plain {
				stack: [64]u8 = ---
				text := scalar_text(doc.src, n, stack[:])
				at := strings.index(string(span), text)
				if at < 0 {
					continue
				}
				span = span[at:][:len(text)]
				n.lo += u64(at)
				n.n = u32(len(span))
			}
			n.spelling = number_form(span)
		}
		n.kind = k
	}
}

@(private)
unmarshal_once :: proc(src: []u8, spec: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, spec, opts)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := text_read(src, bound_as(spec, opts), target, T, &plan, read, allocator)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_plan :: proc(src: []u8, spec: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(text_read(src, bound_as(spec, opts), target, T, plan, read, allocator))
}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc(src: []u8, spec: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return typed.check_by(src, bound_as(spec, options_of(typed.handle_of(plan))), target, T, plan, read, allocator, text_check)
}

// The `spelling` of a number token whose text is `text`: a JSON number carries its digit counts, and any other form
// carries the kind a writer converts it by.
@(private)
number_form :: proc(text: []u8) -> u16 {
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'x': return 4
		case 'o': return 6
		}
	}
	if classify(text) == .Inf {
		return 10
	}
	if classify(text) == .Nan {
		return 12
	}
	at := 1 if text[0] == '-' else 0
	digits := at
	for digits < len(text) && text[digits] >= '0' && text[digits] <= '9' {
		digits += 1
	}
	whole := digits - at
	if whole == 0 || whole > 1 && text[at] == '0' {
		return core.NUMBER_DECIMAL
	}
	frac, exp := 0, false
	if digits < len(text) && text[digits] == '.' {
		end := digits + 1
		for end < len(text) && text[end] >= '0' && text[end] <= '9' {
			end += 1
		}
		frac = end - digits - 1
		if frac == 0 {
			return core.NUMBER_DECIMAL
		}
		digits = end
	}
	if digits < len(text) {
		if text[digits] | 0x20 != 'e' {
			return core.NUMBER_DECIMAL
		}
		exp = true
		at = digits + 1
		if at < len(text) && (text[at] == '+' || text[at] == '-') {
			at += 1
		}
		if at == len(text) {
			return core.NUMBER_DECIMAL
		}
		for b in text[at:] {
			if b < '0' || b > '9' {
				return core.NUMBER_DECIMAL
			}
		}
	}
	form := core.number_spelling(0, u64(whole), u64(frac))
	return form | core.NUMBER_EXP if exp else form
}
