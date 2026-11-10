package write

// A value written in any format with a token writer. A node is written by the readers, as a built value is, so its
// text is spelled new. A value's comments are not written, and an object's members are written in order, a repeated
// key each time.

import "base:runtime"
import core ".."
import "../typed"

// Writes `v` in the format `as` names, as `opts` says, into new bytes from `allocator`. A format with no token writer
// is `.Unsupported` and a value nested past `core.MAX_DEPTH` levels `.Too_Deep`.
write_value :: proc(v: core.Value, as: core.As, opts := core.Write_Options{}, allocator := context.allocator) -> (text: []u8, err: core.Typed_Error) {
	t: Tokens = ---
	if kind := tokens_init(&t, as, opts, allocator); kind != .None {
		tokens_finish(&t)
		return nil, {kind = kind}
	}
	put_value(&t, v)
	return tokens_finish(&t)
}

// `v` in `plan`'s format, as a format's plans write a built value for `typed.unmarshal`.
value_text :: proc(plan: ^typed.Plan, v: core.Value, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error) {
	t: Tokens = ---
	if kind := tokens_init(&t, plan.as, {}, allocator, {}, (^Token_Spelling)(plan.tokens)); kind != .None {
		tokens_finish(&t)
		return nil, {kind = kind}
	}
	put_value(&t, v)
	return tokens_finish(&t)
}

// `v` of type `T` as a built value by `plan`, which a format built, in `allocator`: the value of the text `marshal`
// writes, read back as `core.built_value` reads a node. A plan with no build, which its reads give, is `.Unsupported`.
marshal_value :: proc(v: $T, plan: ^typed.Plan, allocator := context.allocator) -> (core.Value, core.Error) {
	v := v
	if plan == nil || plan.build == nil {
		return nil, core.error_of(core.Typed_Error{kind = .Unsupported})
	}
	text, merr := marshal(v, plan)
	defer delete(text)
	if merr != nil {
		return nil, merr
	}
	doc, err := plan.build(text, plan.as, context.allocator)
	if err.kind != .None {
		return nil, core.error_of(err)
	}
	defer core.destroy(&doc)
	context.allocator = allocator
	return core.built_value({&doc, core.ROOT}), nil
}

@(private = "file")
put_value :: proc(t: ^Tokens, v: core.Value) -> core.Typed_Error_Kind {
	switch x in core.plain(v) {
	case nil:
		return value_null(t)
	case bool:
		return value_bool(t, x)
	case f64:
		n, _ := core.number(v)
		return value(t, n)
	case ^core.Number_Text:
		return value(t, Number_Literal{x.text})
	case string:
		return value_string(t, x)
	case ^core.Array:
		open_array(t) or_return
		for m in x.items {
			put_value(t, m) or_return
		}
		return close(t)
	case ^core.Object:
		open_object(t) or_return
		for k, i in x.keys {
			key(t, k) or_return
			put_value(t, x.vals[i]) or_return
		}
		return close(t)
	case core.Node_Ref:
		return put_node(t, x)
	case core.Trail:
		return put_value(t, core.trail_array(x))
	case ^core.Commented:
	}
	return .None
}

@(private = "file")
put_node :: proc(t: ^Tokens, r: core.Node_Ref) -> core.Typed_Error_Kind {
	#partial switch core.kind(r) {
	case .Null:
		return value_null(t)
	case .False:
		return value_bool(t, false)
	case .True:
		return value_bool(t, true)
	case .Number:
		if _, digits, _ := core.double_of(r); digits != "" {
			return value(t, Number_Literal{digits})
		}
		n, _ := core.number(r)
		return value(t, n)
	case .String:
		return value_string(t, core.node_string(r.doc, r.node))
	case .Array:
		open_array(t) or_return
		it := core.children(r)
		for m in core.child_next(&it) {
			put_value(t, m) or_return
		}
		return close(t)
	case .Object:
		open_object(t) or_return
		it := core.pairs(r)
		for k, m in core.pair_next(&it) {
			key(t, k) or_return
			put_value(t, m) or_return
		}
		return close(t)
	}
	return .None
}
