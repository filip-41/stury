package write

// A value written in any format with a token writer. A node is written by the readers, as a built value is, so its
// text is spelled new. A value's comments are not written, and an object's members are written in order, a repeated
// key each time. A string with a tag, written on it or its node's, is a `Tagged_Text`.

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
	text, refusal = write_laid(v, as, opts, "", nil, allocator)
	return text, core.error_of(refusal)
}

// `write_value` with the bytes between a member's key and its value given as `colon`, unless empty, and a format
// that binds its spelling at compile time giving it as `spelling`. `site` is where the text will stand, as
// `tokens_init` takes it. The refusal is the writer's own.
write_laid :: proc(v: core.Value, as: core.As, opts: core.Write_Options, colon: string, spelling: ^Token_Spelling, allocator := context.allocator, site := core.Site{}) -> (text: []u8, err: core.Typed_Refusal) {
	spelling := spelling
	if spelling == nil && colon != "" {
		services := core.services_of(as)
		if services == nil || services.tokens == nil {
			return nil, {kind = .Unsupported}
		}
		spelling = (^Token_Spelling)(services.tokens)
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
	value_of(&t, v)
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

// A value of any form, written as `marshal` writes it. With `comments` the comments written on a value (`Commented`) go
// before it where the format has comments, and without it they are left out.
value_of :: proc(t: ^Tokens, v: core.Value, comments := false) -> core.Typed_Error_Kind {
	if comments {
		lead_comments(t, v) or_return
	}
	return value_plain(t, v, comments)
}

// The comments before the value `v`, which `comment` writes where a key does not wait for its value.
@(private = "file")
lead_comments :: proc(t: ^Tokens, v: core.Value) -> core.Typed_Error_Kind {
	if c, is_commented := v.(^core.Commented); is_commented && .Comment in c.written {
		for body in c.bodies[.Comment] {
			comment(t, body) or_return
		}
	}
	return .None
}

@(private = "file")
value_plain :: proc(t: ^Tokens, v: core.Value, comments: bool) -> core.Typed_Error_Kind {
	switch x in core.plain(v) {
	case nil:
		return value_null(t)
	case bool:
		return value_bool(t, x)
	case f64:
		if t.opts.jq_numbers && (math.is_nan(x) || math.is_inf(x)) {
			return value_null(t) if math.is_nan(x) else value_float(t, math.copy_sign(math.F64_MAX, x))
		}
		n, _ := core.number(v)
		return value(t, n)
	case ^core.Number_Text:
		return value(t, Number_Literal{x.text})
	case string:
		if tag, tagged := string_tag(v); tagged {
			return value(t, Tagged_Text{x, tag})
		}
		return value_string(t, x)
	case ^core.Array:
		open_array(t) or_return
		for m in x.items {
			value_of(t, m, comments) or_return
		}
		return close(t)
	case ^core.Object:
		open_object(t) or_return
		if t.opts.sort_keys && len(x.keys) > 1 {
			for m in sorted(x.keys[:], x.vals[:]) {
				if comments {
					lead_comments(t, m.val) or_return
				}
				key(t, m.key) or_return
				value_plain(t, m.val, comments) or_return
			}
			return close(t)
		}
		for k, i in x.keys {
			if comments {
				lead_comments(t, x.vals[i]) or_return
			}
			key(t, k) or_return
			value_plain(t, x.vals[i], comments) or_return
		}
		return close(t)
	case core.Node_Ref:
		return put_node(t, x, v)
	case core.Trail:
		return value_of(t, core.trail_array(x), comments)
	case ^core.Commented:
	}
	return .None
}

// The tag string `v` is written with: the one written on it, else its node's, and false for none.
@(private = "file")
string_tag :: proc(v: core.Value) -> (string, bool) {
	if c, is_commented := v.(^core.Commented); is_commented && .Tag in c.written {
		bodies := c.bodies[.Tag]
		return bodies[0] if len(bodies) > 0 else "", len(bodies) > 0
	}
	r, is_ref := core.plain(v).(core.Node_Ref)
	if !is_ref || len(r.doc.facts) == 0 && r.doc.readers.fact == nil {
		return "", false
	}
	tag, tagged := core.fact_value(r.doc, r.node, .Tag)
	return tag.text, tagged
}

// Node `r` of `v`, which may write a tag on it.
@(private = "file")
put_node :: proc(t: ^Tokens, r: core.Node_Ref, v: core.Value) -> core.Typed_Error_Kind {
	#partial switch core.kind(r) {
	case .Null:
		return value_null(t)
	case .False:
		return value_bool(t, false)
	case .True:
		return value_bool(t, true)
	case .Number:
		// The digits a format spells for a number whose span is not its text are read into `spelled`.
		spelled: [core.HEX_ROOM]u8
		if _, digits, _ := core.double_of(r, spelled[:] if r.doc.readers.number_text != nil else nil); digits != "" {
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
		if tag, tagged := string_tag(v); tagged {
			return value(t, Tagged_Text{core.node_string(r.doc, r.node), tag})
		}
		return value_string(t, core.node_string(r.doc, r.node))
	case .Array:
		open_array(t) or_return
		it := core.children(r)
		for m in core.child_next(&it) {
			value_of(t, m) or_return
		}
		return close(t)
	case .Object:
		open_object(t) or_return
		it := core.pairs(r)
		if t.opts.sort_keys {
			keys := make([dynamic]string, context.temp_allocator)
			vals := make([dynamic]core.Value, context.temp_allocator)
			for k, m in core.pair_next(&it) {
				append(&keys, k)
				append(&vals, m)
			}
			for m in sorted(keys[:], vals[:]) {
				key(t, m.key) or_return
				value_of(t, m.val) or_return
			}
			return close(t)
		}
		for k, m in core.pair_next(&it) {
			key(t, k) or_return
			value_of(t, m) or_return
		}
		return close(t)
	}
	return .None
}

@(private = "file")
Member :: struct {
	key: string,
	val: core.Value,
}

// The members of an object in key order, a repeated key staying in its order.
@(private = "file")
sorted :: proc(keys: []string, vals: []core.Value) -> []Member {
	members := make([]Member, len(keys), context.temp_allocator)
	for k, i in keys {
		members[i] = {k, vals[i]}
	}
	slice.stable_sort_by(members, proc(a, b: Member) -> bool {return a.key < b.key})
	return members
}
