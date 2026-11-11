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

// Binds `c` to `from` and `to`, each with the typed reads of its format as `bind` takes them. A schema `to` cannot bind is a `.Write` refusal of the caller's.
converter_init :: proc(cv: ^Converter, c: ^Compiled, from, to: core.As, from_reads: ^typed.Format_Reads = nil, to_reads: ^typed.Format_Reads = nil) -> (err: core.Error) {
	cv.to = to
	cv.from = bind(c, {from_reads, from}) or_return
	defer if err != nil {
		unbind(&cv.from)
	}
	cv.into = bind(c, {to_reads, to}) or_return
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
// checked as it stands, each cell read as its format reads it and a markup text as the check read it by the arm it
// decides, then its data model is written whole, so a member the
// schema leaves open survives, and the text is checked again as the output format reads it, the schema picking the kind
// of each of its cells. A value the output format cannot spell is a refusal that names its path, and a text that fails
// the schema is the check's failures, in `sink` when one is given, whose positions are in the text that stage returns
// with it. A format with attributes writes each as a member before the element's children, a name its children repeat
// as an array and its text as `#text` when the element has attributes. An attribute and a child of one name, and an
// array with attributes, are refused.
convert :: proc(cv: ^Converter, doc: ^core.Document, opts := core.Write_Options{}, sink: ^typed.Sink = nil, allocator := context.allocator) -> (text: []u8, stage: Stage, err: core.Error) {
	virtual.arena_free_all(&cv.arena)
	scratch := virtual.arena_allocator(&cv.arena)
	// A markup text's kind is the one the check read it as, and a flat cell's the one its format reads.
	readings: typed.Readings
	readings.read.allocator = scratch
	markup := doc.readers != nil && doc.readers.attribute != nil
	if err = check_node(&cv.from, doc, core.ROOT, sink, &readings if markup else nil); err != nil {
		return nil, .Input, err
	}
	if readings.short {
		return nil, .Input, core.error_of(core.Typed_Refusal{kind = .No_Memory}, allocator)
	}
	context.allocator = scratch
	m := Model{to = cv.to, flat = cv.to.readers != nil && cv.to.readers.flat, read = make(map[u64]core.Kind, len(readings.read))}
	for r in readings.read {
		m.read[r.lo] = r.kind
	}
	v := build(&m, core.Node_Ref{doc, core.ROOT})
	if m.refused {
		return nil, .Write, refusal(m.kind, m.steps[:], allocator)
	}
	wrote: Refusal
	if text, wrote = written(v, cv.to, opts, allocator); wrote.kind != .None {
		delete(text, allocator)
		return nil, .Write, locate(&m, doc, wrote, allocator)
	}
	context.allocator = allocator
	if err = output_check(cv, text, sink); err != nil {
		return text, .Output, err
	}
	return text, .Input, nil
}

// The text carries the data the schema describes, so the schema picks its cells' kinds as the output is read back.
@(private = "file")
output_check :: proc(cv: ^Converter, text: []u8, sink: ^typed.Sink) -> core.Error {
	picked: typed.Readings
	picked.read.allocator = virtual.arena_allocator(&cv.arena)
	defer virtual.arena_free_all(&cv.arena)
	return check_reading(&cv.into, text, sink, nil, nil, &picked)
}

// What the data model of a conversion is built with.
@(private = "file")
Model :: struct {
	to:      core.As,
	flat:    bool,
	steps:   [dynamic]core.Step,
	// The kind the check read each markup text as, by its first byte.
	read:    map[u64]core.Kind,
	refused: bool,
	kind:    core.Typed_Error_Kind,
	probe:   bool,
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

// The data model of `v`. A document with attributes is rebuilt, so that a node is an object of its attributes, then its
// children, or its text as `#text` when it has any, and a name its children repeat is an array. Any other value is
// itself, unless the model is probing, which tries each scalar alone against the output format.
@(private = "file")
build :: proc(m: ^Model, v: core.Value) -> core.Value {
	ref, is_node := v.(core.Node_Ref)
	if m.refused || !is_node {
		return v
	}
	markup := ref.doc.readers != nil && ref.doc.readers.attribute != nil
	if !m.probe && !markup {
		return v
	}
	attributes := core.attributes_of(ref.doc, ref.node)
	members := attribute_members(m, ref, &attributes)
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
		return object(m, v, members if members != nil else core.new_object(), markup)
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

// A scalar of the model: tried alone against the output format when probing, else as the check read it.
@(private = "file")
scalar :: proc(m: ^Model, v: core.Value) -> core.Value {
	if m.probe {
		if _, wrote := written(v, m.to, {}, context.temp_allocator); wrote.kind != .None {
			refuse(m, wrote.kind)
		}
		return v
	}
	ref, is_node := v.(core.Node_Ref)
	if !is_node {
		return v
	}
	if kind, read := m.read[ref.doc.nodes[ref.node].lo]; read {
		return read_as(core.node_string(ref.doc, ref.node), kind)
	}
	return v
}

// The value of `text` as the check read it, as `kind`.
@(private = "file")
read_as :: proc(text: string, kind: core.Kind) -> core.Value {
	#partial switch kind {
	case .Null:
		return nil
	case .True, .False:
		return kind == .True
	case .Number:
		return core.number_text(strict_spelling(text))
	}
	return text
}

// `text`, a number by the loose grammar, spelled by the strict one: no `+`, no leading zero, and a digit on each side of
// a point.
@(private = "file")
strict_spelling :: proc(text: string) -> string {
	if kind, _ := core.plain_kind(transmute([]u8)text, 0, u64(len(text)), false, true); kind == .Number {
		return text
	}
	b := strings.builder_make()
	s := text
	if s[0] == '-' {
		strings.write_byte(&b, '-')
	}
	if s[0] == '-' || s[0] == '+' {
		s = s[1:]
	}
	point := strings.index_any(s, ".eE")
	if point < 0 {
		point = len(s)
	}
	whole := strings.trim_left(s[:point], "0")
	strings.write_string(&b, whole if whole != "" else "0")
	s = s[point:]
	if len(s) > 0 && s[0] == '.' {
		s = s[1:]
		exponent := strings.index_any(s, "eE")
		if exponent < 0 {
			exponent = len(s)
		}
		if exponent > 0 {
			strings.write_byte(&b, '.')
			strings.write_string(&b, s[:exponent])
		}
		s = s[exponent:]
	}
	strings.write_string(&b, s)
	return strings.to_string(b)
}

// The attributes of an element as an object, each value as the check read it, nil for an element with none.
@(private = "file")
attribute_members :: proc(m: ^Model, ref: core.Node_Ref, attributes: ^core.Attribute_Iter) -> ^core.Object {
	name, value, held := core.attribute_next(attributes)
	if !held {
		return nil
	}
	members := core.new_object()
	for ; held; name, value, held = core.attribute_next(attributes) {
		key, _ := core.token_text(ref.doc.readers, &ref.doc.view, name, context.allocator)
		text, _ := core.token_text(ref.doc.readers, &ref.doc.view, value, context.allocator)
		kind, read := m.read[value.lo]
		core.object_put(members, key, read_as(text, kind) if read else text)
	}
	return members
}

// The children of an object node added to `members`. In a document with attributes a name repeated is an array at the
// place of its first, and none may share a name with an attribute.
@(private = "file")
object :: proc(m: ^Model, v: core.Value, members: ^core.Object, markup: bool) -> core.Value {
	it := core.value_pairs(v)
	if !markup {
		for key, child in core.value_pair_next(&it) {
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
