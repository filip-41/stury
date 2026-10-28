package json

// `unmarshal` of a JSON5 text, read from its rows.

import "base:runtime"
import "core:bytes"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"

// Read the JSON5 text `src` as `read_planned` reads JSON: built as a document, then read from its rows
// (`core_pkg.shape_rows`). A number reads as its JSON decimal spelling, and a value read whole (`Raw`, `any`,
// a bit_set or a hook's text) as its JSON text with its comments. `Infinity` and `NaN`, which have no JSON
// spelling, are `.Out_Of_Range` where they are read. A refusal's offset and key names point into `src`.
@(private)
read_json5 :: proc(src: []byte, dest: rawptr, opts: Unmarshal_Opts, plan: ^Format_Plan, allocator: runtime.Allocator) -> Maybe(Unmarshal_Error) {
	// A repeat refused outranks a fault after it, as in JSON, so the build refuses it.
	refuse := Duplicates.Refuse if opts.duplicates == .Refuse else Duplicates.Default
	doc, berr := build(src, {dialect = .Json5, limits = opts.limits, duplicates = refuse})
	defer destroy(&doc)
	if e, bad := berr.?; bad {
		if e.kind == .Duplicate_Key {
			return Unmarshal_Error{kind = .Duplicate_Key, offset = e.offset}
		}
		return core_pkg.unmarshal_error_from(e)
	}
	shape, serr := core_pkg.read_shape_of(&plan.base)
	if serr != nil {
		return serr
	}
	frames: [MAX_DEPTH]walk.Shape_Frame = ---
	wide: [walk.SHAPE_WIDE_WORDS]u64 = ---
	run := walk.Shape_Run{frames = &frames, wide = wide[:], src = src, allocator = allocator}
	shape_run_bind(&run, shape, plan, opts)
	rd := Json5_Read{doc = &doc}
	defer delete(rd.text)
	e, refused := core_pkg.shape_rows(&run, &doc, dest, MAX_DEPTH, &rd, json5_leaf).?
	if !refused {
		return nil
	}
	err := Unmarshal_Error{offset = e.offset}
	steps := run.sp
	if e.kind == walk.TYPED_FAULT {
		err.kind = Unmarshal_Error_Kind(run.fault)
		if at, non_finite := rd.non_finite_at.?; non_finite {
			err.offset = at
		}
		steps = u64(run.fault_steps)
	} else {
		err.kind, err.syntax = .Syntax, e.kind
	}
	key := Json5_Key{src = src, allocator = allocator}
	core_pkg.shape_error_path(&run, &err, steps, &key, json5_key_name)
	return err
}

@(private = "file")
Json5_Read :: struct {
	doc:  ^Document,
	text:          [dynamic]u8, // the JSON text of the value `json5_leaf` reads, reused
	non_finite_at: Maybe(u64), // the `Infinity` or `NaN` that refused the value read
}

// Value `n` read by JSON's leaves from its JSON text: a number into a numeric, `Number`, `Digits` or `Decoded`
// target, and any value into a `Raw`, `any`, bit_set or hooked one. The text lives until the next value, so
// nothing borrows it.
@(private = "file")
json5_leaf :: proc(rd: ^Json5_Read, r: ^walk.Shape_Run, n: Node, op: ^core_pkg.Shape_Op, dest: rawptr) -> core_pkg.Shape_Fault {
	clear(&rd.text)
	#partial switch node_json(&rd.text, rd.doc, n) {
	case .None:
	case .Non_Finite:
		rd.non_finite_at = non_finite_at(rd.doc, n)
		return .Out_Of_Range
	case:
		return .Out_Of_Memory
	}
	t := rd.text[:]
	hi := u64(len(t))
	borrow := r.borrow
	r.borrow = false
	defer r.borrow = borrow
	number := core_pkg.number_starts_with(t[0])
	#partial switch op.kind {
	case .Int, .Uint:
		return core_pkg.shape_leaf_int(t, 0, hi, dest, op.width, op.kind == .Int)
	case .Wide_Int, .Wide_Uint:
		return core_pkg.shape_leaf_wide(t, 0, hi, dest, op.kind == .Wide_Int)
	case .Enum_Int, .Enum_Uint:
		return core_pkg.shape_leaf_enum(t, 0, hi, dest, op)
	case .Float:
		if !number {
			return .Wrong_Kind
		}
		return core_pkg.shape_leaf_float_lexed(t, 0, hi, core_pkg.lex_number_value(t, 0, hi), dest, op.width)
	case .Number:
		if !number {
			return .Wrong_Kind
		}
		if dest != nil {
			(^Number)(dest)^ = core_pkg.number_span(t, 0, hi)
		}
		return .None
	case .Digits:
		if !number {
			return .Wrong_Kind
		}
		return scan_pkg.shape_leaf_raw(r, t, 0, hi, dest)
	case .Decoded:
		return scan_pkg.shape_leaf_decoded(r, t, 0, hi, dest, bytes.index_byte(t, '\\') >= 0, 0, false)
	}
	return scan_pkg.shape_leaf_whole(r, t, 0, hi, dest, op)
}

@(private = "file")
Json5_Key :: struct {
	src:       []byte,
	allocator: runtime.Allocator,
}

// The key `src[lo:hi]` as authored, unquoted; decoded into the caller's allocator when it holds an escape.
@(private = "file")
json5_key_name :: proc(k: ^Json5_Key, lo, hi: u64) -> string {
	lo, hi := lo, hi
	src := k.src
	if bytes.index_byte(src[lo:hi], '\\') >= 0 {
		decoded := make([]byte, hi - lo, k.allocator)
		if decoded != nil {
			return string(decoded[:scan_pkg.json5_unescape_into(decoded, src, lo, hi, 0)])
		}
	}
	if src[lo] == '"' || src[lo] == '\'' {
		lo, hi = lo + 1, hi - 1
	}
	return string(src[lo:hi])
}
