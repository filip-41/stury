package write

// A value written in any format with a token writer. A node is written by the readers, as a built value is, so its
// text is spelled new, in the style its node or the value holds (`core.value_style`), strings but under
// `respell_strings`. An object's members are written in order, a repeated key each time. A string with a tag, written
// on it or its node's, is a `Tagged_Text`.

import "base:runtime"
import "core:math"
import "core:slice"
import core ".."
import "../typed"

// Writes `v` in the format `as` names, as `opts` says, into new bytes from `allocator`. A format with no token writer
// is `.Unsupported` and a value nested past `core.MAX_DEPTH` levels `.Too_Deep`. Under `opts.sort_keys` an object's
// members are written in key order.
write_value :: proc(v: core.Value, as: core.As, opts := core.Write_Options{}, allocator := context.allocator) -> (text: []u8, err: core.Error) {
	refusal: core.Typed_Refusal
	text, refusal = write_laid(v, as, opts, "", nil, allocator, comments = true)
	return text, core.error_of(refusal)
}

// `write_value` with the bytes between a member's key and its value given as `colon`, unless empty, and a format
// that binds its spelling at compile time giving it as `spelling`. `site` is where the text will stand, as
// `tokens_init` takes it. `comments` writes the value's comments, which an edit writes itself. The refusal is the
// writer's own.
write_laid :: proc(v: core.Value, as: core.As, opts: core.Write_Options, colon: string, spelling: ^Token_Spelling, allocator := context.allocator, site := core.Site{}, comments := false) -> (text: []u8, err: core.Typed_Refusal) {
	spelling := spelling
	if services := core.services_of(as); spelling == nil && services != nil {
		spelling = (^Token_Spelling)(services.tokens)
	}
	if spelling != nil && spelling.built != nil {
		return spelling.built(v, opts, {}, allocator)
	}
	if spelling == nil && colon != "" {
		return nil, {kind = .Unsupported}
	}
	laid: Token_Spelling
	if colon != "" {
		laid = spelling^
		laid.tree[.Colon], laid.tree[.After_Colon] = colon, ""
		spelling = &laid
	}
	t: Tokens = ---
	if kind := tokens_init(&t, as, opts, allocator, {}, spelling, site); kind != .None {
		tokens_finish(&t)
		return nil, {kind = kind}
	}
	value_of(&t, v, comments)
	return tokens_finish(&t)
}

// `v` in `plan`'s format, as a format's plans write a built value for `typed.unmarshal`.
value_text :: proc(plan: ^typed.Plan, v: core.Value, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	t: Tokens = ---
	if kind := tokens_init(&t, plan.as, {}, allocator, {}, (^Token_Spelling)(plan.tokens)); kind != .None {
		tokens_finish(&t)
		return nil, {kind = kind}
	}
	value_of(&t, v)
	return tokens_finish(&t)
}

// `v` of type `T` as a built value by `plan`, which a format built, in `allocator`: the value of the text `marshal`
// writes, read back as `core.built_value` reads a node. A plan with no build, which its reads give, is `.Unsupported`.
@(private)
marshal_value :: proc(v: $T, plan: ^typed.Plan, allocator := context.allocator) -> (core.Value, core.Error) {
	v := v
	if plan == nil || typed.plan_text_build(plan) == nil {
		return nil, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	text, merr := marshal(v, plan)
	defer delete(text)
	if merr != nil {
		return nil, merr
	}
	doc, err := typed.plan_text_build(plan)(text, plan.as, context.allocator)
	if err.kind != .None {
		return nil, core.error_of(err)
	}
	defer core.destroy(&doc)
	context.allocator = allocator
	return core.built_value({&doc, core.ROOT}), nil
}

// A value of any form, written as `marshal` writes it. With `comments` its comments, written on it (`Commented`) or its
// node's, are written where the format has comments, and without it they are left out.
value_of :: proc(t: ^Tokens, v: core.Value, comments := false) -> core.Typed_Error_Kind {
	notes := comments && t.notes
	put_notes(t, v, .Comment, notes) or_return
	value_plain(t, v, notes) or_return
	return put_notes(t, v, .Comment_Inline, notes)
}

// A member of an object: its lead comments, its key, its value and its inline comments.
@(private = "file")
member :: proc(t: ^Tokens, name: string, v: core.Value, notes: bool) -> core.Typed_Error_Kind {
	put_notes(t, v, .Comment, notes) or_return
	key(t, name) or_return
	value_plain(t, v, notes) or_return
	return put_notes(t, v, .Comment_Inline, notes)
}

// The comments of `role` on `v` when `notes`. A scalar's foot follows it.
@(private = "file")
put_notes :: proc(t: ^Tokens, v: core.Value, role: core.Role, notes: bool) -> core.Typed_Error_Kind {
	if !notes {
		return .None
	}
	context.allocator = context.temp_allocator
	bodies, _ := core.comments(v, role)
	for body in bodies {
		comment(t, body, role) or_return
	}
	return .None
}

@(private = "file")
value_plain :: proc(t: ^Tokens, v: core.Value, notes: bool) -> core.Typed_Error_Kind {
	switch x in core.plain(v) {
	case nil:
		value_null(t) or_return
	case bool:
		value_bool(t, x) or_return
	case f64:
		if t.opts.jq_numbers && (math.is_nan(x) || math.is_inf(x)) {
			(value_null(t) if math.is_nan(x) else value_float(t, math.copy_sign(math.F64_MAX, x))) or_return
		} else {
			n, _ := core.number(v)
			value(t, n) or_return
		}
	case core.Number_View:
		value(t, Number_Literal{core.view_text(x)}) or_return
	case string:
		if tag, tagged := string_tag(v); tagged {
			value(t, Tagged_Text{x, tag.text, tag.meaning}) or_return
		} else {
			value_string(t, x) or_return
		}
	case ^core.Array:
		open_array(t) or_return
		for m in x.items {
			value_of(t, m, notes) or_return
		}
		return close_noted(t, v, notes)
	case ^core.Object:
		open_object(t) or_return
		keys, vals := core.object_keys(x), core.object_vals(x)
		if t.opts.sort_keys && len(keys) > 1 {
			for m in sorted(x) {
				member(t, m.key, m.val, notes) or_return
			}
		} else {
			for k, i in keys {
				member(t, k, vals[i], notes) or_return
			}
		}
		return close_noted(t, v, notes)
	case core.Node_Ref:
		return put_node(t, x, v, notes)
	case core.Trail:
		return value_plain(t, core.trail_array(x), notes)
	case ^core.Commented:
	}
	return put_notes(t, v, .Comment_Foot, notes)
}

// Closes the container `v` after its foot comments.
@(private = "file")
close_noted :: proc(t: ^Tokens, v: core.Value, notes: bool) -> core.Typed_Error_Kind {
	put_notes(t, v, .Comment_Foot, notes) or_return
	return close(t)
}

// The tag `v` is written with: the one written on it, else its node's with its meaning, and false for none.
@(private = "file")
string_tag :: proc(v: core.Value) -> (core.Fact_Value, bool) {
	if c, is_commented := v.(^core.Commented); is_commented && .Tag in c.written {
		bodies := c.bodies[.Tag]
		return {text = bodies[0] if len(bodies) > 0 else ""}, len(bodies) > 0
	}
	r, is_ref := core.plain(v).(core.Node_Ref)
	if !is_ref || len(r.doc.facts) == 0 && r.doc.readers.fact == nil {
		return {}, false
	}
	return core.fact_value(r.doc, r.node, .Tag)
}

// Node `r` of `v`, which may write a tag on it.
@(private = "file")
put_node :: proc(t: ^Tokens, r: core.Node_Ref, v: core.Value, notes: bool) -> core.Typed_Error_Kind {
	#partial switch core.kind(r) {
	case .Null:
		return value_null(t)
	case .False:
		return value_bool(t, false)
	case .True:
		return value_bool(t, true)
	case .Number:
		t.style = core.value_style(v)
		// The digits of a number whose span is not a JSON number are read into `spelled`.
		spelled: [core.HEX_ROOM]u8
		if _, digits, _ := core.double_of(r, spelled[:]); digits != "" {
			return value(t, Number_Literal{digits})
		}
		n, _ := core.number(r)
		return value(t, n)
	case .Bytes:
		// A payload in chunks is joined in the temp allocator.
		joined: []u8
		if room := core.text_room(r.doc, r.node); room > 0 {
			joined = make([]u8, room, context.temp_allocator) or_else nil
		}
		payload, held := core.doc_bytes(r.doc, r.node, joined)
		return value_bytes(t, payload) if held else .No_Memory
	case .String:
		if !t.opts.respell_strings {
			t.style = core.value_style(v)
		}
		if tag, tagged := string_tag(v); tagged {
			return value(t, Tagged_Text{core.node_string(r.doc, r.node), tag.text, tag.meaning})
		}
		return value_string(t, core.node_string(r.doc, r.node))
	case .Array:
		open_array(t) or_return
		it := core.children(r)
		for m in core.child_next(&it) {
			value_of(t, m, notes) or_return
		}
		return close_noted(t, v, notes)
	case .Object:
		open_object(t) or_return
		if t.opts.sort_keys {
			for m in sorted(r) {
				member(t, m.key, m.val, notes) or_return
			}
			return close_noted(t, v, notes)
		}
		it := core.pairs(r)
		for k, m in core.pair_next(&it) {
			member(t, k, m, notes) or_return
		}
		return close_noted(t, v, notes)
	}
	return .None
}

@(private = "file")
Member :: struct {
	key: string,
	val: core.Value,
}

// The members of object `v` in key order, a repeated key staying in its order, in the temp allocator.
@(private = "file")
sorted :: proc(v: core.Value) -> []Member {
	members := make([dynamic]Member, context.temp_allocator)
	it := core.pairs(v)
	for k, m in core.pair_next(&it) {
		append(&members, Member{k, m})
	}
	slice.stable_sort_by(members[:], proc(a, b: Member) -> bool {return a.key < b.key})
	return members[:]
}
