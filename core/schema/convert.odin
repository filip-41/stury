package schema

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import core "../"
import "../typed"

// Where a conversion stopped: the input failing the schema, the output format refusing a value, or the output failing
// the schema.
Stage :: enum u8 {
	Input,
	Write,
	Output,
}

// A schema bound to the format a conversion reads and the one it writes, and the scratch memory every conversion
// of a run reuses.
Converter :: struct {
	from, into: Bound,
	to:         core.As,
	arena:      virtual.Arena,
}

// The most times a conversion rewrites a text to settle which reading each Plain node takes.
READING_ROUNDS :: 16

// The most failures of the output a round reads the readings from.
READING_FAILURES :: 4096

// Binds `c` to `from` and `to`, each with the typed reads of its format as `bind` takes them. A schema `to` cannot bind is a `.Write` refusal of the caller's.
converter_init :: proc(cv: ^Converter, c: ^Compiled, from, to: core.As, from_reads: ^typed.Format_Reads = nil, to_reads: ^typed.Format_Reads = nil) -> (err: core.Error) {
	cv.to = to
	cv.from = bind(c, from, from_reads) or_return
	defer if err != nil {
		unbind(&cv.from)
	}
	cv.into = bind(c, to, to_reads) or_return
	if virtual.arena_init_growing(&cv.arena) != nil {
		unbind(&cv.into)
		return core.error_of(core.Typed_Refusal{kind = .No_Memory})
	}
	return
}

converter_destroy :: proc(cv: ^Converter) {
	virtual.arena_destroy(&cv.arena)
	unbind(&cv.into)
	unbind(&cv.from)
}

// Converts `doc`, a document the schema describes in the format `cv` reads, to the format it writes. The document is
// checked as it stands, then its data model is written whole, so a member the schema leaves open survives, and the
// text is checked again as the output format reads it. A text that fails there is written again with the other reading
// for each Plain node the failures name, a string or the value its text spells, so the arm the schema decides is the
// one written. A value the output format cannot spell is a refusal that names its path, and a text that fails the
// schema is the check's failures, in `sink` when one is given, whose positions are in the text that stage returns with
// it. A format with attributes writes each as a member before the element's children, a name its children repeat as
// an array and its text as `#text` when the element has attributes. An attribute and a child of one name, and an
// array with attributes, are refused. An empty cell of a flat format is a member that is absent.
convert :: proc(cv: ^Converter, doc: ^core.Document, opts := core.Write_Options{}, sink: ^typed.Sink = nil, allocator := context.allocator) -> (text: []u8, stage: Stage, err: core.Error) {
	if err = check_node(&cv.from, doc, core.ROOT, sink); err != nil {
		return nil, .Input, err
	}
	virtual.arena_free_all(&cv.arena)
	scratch := virtual.arena_allocator(&cv.arena)
	context.allocator = scratch
	m := Model{to = cv.to, flat = cv.to.readers != nil && cv.to.readers.flat}
	trial := typed.Sink{max_errors = READING_FAILURES}
	for round := 0; ; round += 1 {
		m.applied, m.refused, m.steps = 0, false, make([dynamic]core.Step)
		v := build(&m, core.Node_Ref{doc, core.ROOT})
		if m.refused {
			return nil, .Write, refusal(m.kind, m.steps[:], allocator)
		}
		written_text, wrote := written(v, cv.to, opts, allocator)
		if wrote.kind != .None {
			delete(written_text, allocator)
			return nil, .Write, locate(&m, doc, wrote, allocator)
		}
		text = written_text
		if err = check(&cv.into, text, &trial); err == nil {
			return text, .Input, nil
		}
		if round == READING_ROUNDS || !flip_failures(&m, &trial) {
			break
		}
		delete(text, allocator)
		typed.sink_restore(&trial, {})
	}
	context.allocator = allocator
	if again := check(&cv.into, text, sink); again != nil {
		err = again
	}
	return text, .Output, err
}

// What the data model of a conversion is built with, and the Plain nodes it reads the other way.
@(private = "file")
Model :: struct {
	to:      core.As,
	flat:    bool,
	steps:   [dynamic]core.Step,
	flips:   map[string]struct{},
	applied: int,
	refused: bool,
	kind:    core.Typed_Error_Kind,
	probe:   bool,
}

// Records the pointers of the nodes the failures of `trial` name, and says whether it learned a new one.
@(private = "file")
flip_failures :: proc(m: ^Model, trial: ^typed.Sink) -> (learned: bool) {
	for e in trial.entries {
		key := pointer(e.path)
		if key not_in m.flips {
			m.flips[key] = {}
			learned = true
		}
	}
	return
}

@(private = "file")
pointer :: proc(steps: []core.Step) -> string {
	b := strings.builder_make()
	core.write_pointer(strings.to_writer(&b), steps)
	return strings.to_string(b)
}

// The refusal `wrote` made, found at a path: of a flat format by its row and member, of any other by building the
// model again with every scalar tried alone.
@(private = "file")
locate :: proc(m: ^Model, doc: ^core.Document, wrote: Refusal, allocator: runtime.Allocator) -> core.Error {
	if m.flat {
		steps := make([dynamic]core.Step, context.temp_allocator)
		if wrote.row >= 0 {
			append(&steps, core.Index(wrote.row))
		}
		if wrote.key != "" {
			append(&steps, core.Name(wrote.key))
		}
		return refusal(wrote.kind, steps[:], allocator)
	}
	m.probe, m.steps = true, make([dynamic]core.Step)
	build(m, core.Node_Ref{doc, core.ROOT})
	return refusal(m.kind if m.refused else wrote.kind, m.steps[:] if m.refused else nil, allocator)
}

@(private = "file")
refusal :: proc(kind: core.Typed_Error_Kind, steps: []core.Step, allocator: runtime.Allocator) -> core.Error {
	e := core.Typed_Refusal{kind = kind}
	kept := steps[max(0, len(steps) - core.MAX_ERROR_STEPS):]
	e.n_steps, e.truncated = u8(len(kept)), len(kept) < len(steps)
	copy(e.steps[:], kept)
	return core.error_of(e, allocator)
}

@(private = "file")
refuse :: proc(m: ^Model, kind: core.Typed_Error_Kind) {
	m.refused, m.kind = true, kind
}

// The data model of `v`. A document with attributes or flat rows is rebuilt, so that a node is an object of its
// attributes, then its children, or its text as `#text` when it has any, a name its children repeat is an array, and a
// flat row has no member for an empty cell. Any other value is itself, unless the model is probing, which tries each
// scalar alone against the output format.
@(private = "file")
build :: proc(m: ^Model, v: core.Value) -> core.Value {
	ref, is_node := v.(core.Node_Ref)
	if m.refused || !is_node {
		return v
	}
	markup := ref.doc.readers != nil && ref.doc.readers.attribute != nil
	flat := ref.doc.readers != nil && ref.doc.readers.flat
	if !m.probe && !markup && !flat {
		return v
	}
	attributes := core.attributes_of(ref.doc, ref.node)
	members := attribute_members(ref, &attributes)
	kind := core.value_kind(v)
	switch {
	case kind == .Array:
		if members != nil {
			refuse(m, .Unwritable)
			return v
		}
		items := core.new_array()
		it := core.value_children(v)
		for i := 0; ; i += 1 {
			child, more := core.value_child_next(&it)
			if !more {
				break
			}
			append(&m.steps, core.Index(i))
			core.array_append(items, build(m, child))
			leave(m)
		}
		return items
	case kind == .Object:
		return object(m, v, members if members != nil else core.new_object(), markup, flat)
	case members != nil:
		if kind != .Null && core.node_string(ref.doc, ref.node) != "" {
			append(&m.steps, core.Name("#text"))
			core.object_put(members, "#text", scalar(m, v))
			leave(m)
		}
		return members
	}
	return scalar(m, v)
}

// Pops the step of a member just built, unless the build refused it, which leaves the path of the refusal.
@(private = "file")
leave :: proc(m: ^Model) {
	if !m.refused {
		pop(&m.steps)
	}
}

// A scalar of the model: tried alone against the output format when probing, and read the other way when the failures
// of the output name it.
@(private = "file")
scalar :: proc(m: ^Model, v: core.Value) -> core.Value {
	if m.probe {
		if _, wrote := written(v, m.to, {}, context.temp_allocator); wrote.kind != .None {
			refuse(m, wrote.kind)
		}
		return v
	}
	ref, is_node := v.(core.Node_Ref)
	if !is_node || len(m.flips) == 0 || !(ref.doc.nodes[ref.node].kind == .Plain || ref.doc.readers != nil && ref.doc.readers.flat) {
		return v
	}
	if pointer(m.steps[:]) not_in m.flips {
		return v
	}
	m.applied += 1
	text := core.node_string(ref.doc, ref.node)
	if core.value_kind(v) != .String {
		return text
	}
	#partial switch kind, _ := core.plain_kind(transmute([]u8)text, 0, u64(len(text)), true, true); kind {
	case .True:
		return true
	case .False:
		return false
	case .Number:
		return core.number_text(text)
	}
	return nil if text == "null" else v
}

// The attributes of an element as an object, nil for an element with none.
@(private = "file")
attribute_members :: proc(ref: core.Node_Ref, attributes: ^core.Attribute_Iter) -> ^core.Object {
	name, value, held := core.attribute_next(attributes)
	if !held {
		return nil
	}
	members := core.new_object()
	for ; held; name, value, held = core.attribute_next(attributes) {
		key, _ := core.token_text(ref.doc.readers, &ref.doc.view, name, context.allocator)
		text, _ := core.token_text(ref.doc.readers, &ref.doc.view, value, context.allocator)
		core.object_put(members, key, text)
	}
	return members
}

// The children of an object node added to `members`. In a document with attributes a name repeated is an array at the
// place of its first, and none may share a name with an attribute. A flat row has no member where the cell is empty.
@(private = "file")
object :: proc(m: ^Model, v: core.Value, members: ^core.Object, markup, flat: bool) -> core.Value {
	it := core.value_pairs(v)
	if !markup {
		for key, child in core.value_pair_next(&it) {
			if flat && core.value_kind(child) == .Null {
				continue
			}
			append(&m.steps, core.Name(key))
			core.object_append(members, key, build(m, child))
			leave(m)
		}
		return members
	}
	Group :: struct {
		key:  string,
		vals: [dynamic]core.Value,
	}
	groups := make([dynamic]Group)
	at := make(map[string]int)
	for key, child in core.value_pair_next(&it) {
		if i, found := at[key]; found {
			append(&groups[i].vals, child)
			continue
		}
		at[key] = len(groups)
		g := Group{key = key}
		append(&g.vals, child)
		append(&groups, g)
	}
	for g in groups {
		append(&m.steps, core.Name(g.key))
		if core.object_slot(members, g.key) >= 0 {
			refuse(m, .Unwritable)
			return v
		}
		if len(g.vals) == 1 {
			core.object_put(members, g.key, build(m, g.vals[0]))
		} else {
			items := core.new_array()
			for child, i in g.vals {
				append(&m.steps, core.Index(i))
				core.array_append(items, build(m, child))
				leave(m)
			}
			core.object_put(members, g.key, items)
		}
		leave(m)
	}
	return members
}
