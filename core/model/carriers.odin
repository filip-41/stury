package model

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/uuid"
import "core:slice"
import "core:strings"
import "core:time"
import core ".."
import rules "../rules"
import typed "../typed"

// Bytes, read and written as RFC 4648 standard base64 with padding and no other padding bits than zero.
Base64 :: distinct []u8

// An email address, judged as the `email` format judges it.
Email :: distinct string

// A number with its digits kept, read from a number or from a string that spells one, and written as a number.
Decimal :: distinct core.Number_Text

// A type a model reads from a string, with the rules every value of it has, the kinds and the content encoding its
// schema names, and its hook, none for a type every plan reads by its own (`time.Time`). The `time.Time` pattern
// refuses a year past 1678 to 2261, in which every offset leaves the time inside the range an `i64` of nanoseconds holds,
// so the read's own range check never refuses what the pattern passed, and leaves a text with no year to the format. `uuid.Identifier` writes lowercase.
@(private)
Carrier :: struct {
	type:     typeid,
	tag:      string,
	subject:  Value_Kinds,
	kinds:    rules.Kinds,
	encoding: string,
	hook:     typed.Type_Hook,
}

@(private, rodata)
CARRIERS := [?]Carrier {
	{time.Time, `format=date-time,pattern=^(?![0-9]{4}-)|^(?:16(?:7[89]|[89][0-9])|1[7-9][0-9]{2}|2[01][0-9]{2}|22(?:[0-5][0-9]|6[01]))-`, {.Text}, {.String}, "", {}},
	{uuid.Identifier, "format=uuid", {.Text}, {.String}, "", {uuid.Identifier, uuid_read, uuid_write, nil, string}},
	{Email, "format=email", {.Text}, {.String}, "", {}},
	{Base64, `pattern=^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/][AQgw]==|[A-Za-z0-9+/]{2}[AEIMQUYcgkosw048]=)?$`, {.Text}, {.String}, "base64", {Base64, base64_read, base64_write, nil, string}},
	{Decimal, `pattern=^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`, {.Text, .Float}, {.Number, .String}, "", {Decimal, decimal_read, decimal_write, nil, Decimal_Text}},
}

// The values a `Decimal` reads.
@(private)
Decimal_Text :: union {
	core.Number_Text,
	string,
}

// The carrier a custom of `reg` reads `T` as, `T` for a type no custom reads.
@(private)
carried :: proc(reg: ^Registry, T: typeid) -> typeid {
	for x in reg.customs {
		if x.type == T {
			return x.carrier
		}
	}
	return T
}

// The carrier `T` is, false for a type that is none.
@(private)
carrier_of :: proc(T: typeid) -> (Carrier, bool) {
	for c in CARRIERS {
		if c.type == T {
			return c, true
		}
	}
	return {}, false
}

// A type `T` a model reads as its carrier `C`, any type the model reads, and converts. `from` makes `out` of a carrier
// read in the temp allocator, allocating what it keeps with `allocator`, or refuses it with a kind. `to` gives the
// carrier a write spells, allocating with `allocator`. A value of `T` has the rules of the type `C` and of its own.
Custom :: struct($T, $C: typeid) {
	from: proc(c: ^C, out: ^T, allocator: runtime.Allocator) -> core.Typed_Error_Kind,
	to:   proc(t: ^T, allocator: runtime.Allocator) -> (C, core.Typed_Error_Kind),
}

// A `Custom` with its types erased, and the plan of its carrier once a model that uses it is compiled.
@(private)
Custom_Of :: struct {
	type, carrier: typeid,
	from, to:      rawptr,
	read:          proc(x: ^Custom_Of, text: []u8, dest: rawptr, allocator: runtime.Allocator) -> core.Typed_Error_Kind,
	write:         proc(x: ^Custom_Of, v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind),
	plan:          typed.Plan,
}

// Reads every value of `T` in the models compiled from `reg` through `custom`.
register_custom :: proc(reg: ^Registry, custom: Custom($T, $C)) -> runtime.Allocator_Error {
	read :: proc(x: ^Custom_Of, text: []u8, dest: rawptr, allocator: runtime.Allocator) -> core.Typed_Error_Kind {
		carrier: C
		#partial switch e in typed.unmarshal_text(text, &carrier, C, &x.plan, {}, context.temp_allocator) {
		case nil:
		case core.Typed_Error:
			return e.kind
		case core.Typed_Error_Kind:
			return e
		case runtime.Allocator_Error:
			return .No_Memory
		case:
			return .Wrong_Kind
		}
		return (proc(c: ^C, out: ^T, allocator: runtime.Allocator) -> core.Typed_Error_Kind)(x.from)(&carrier, (^T)(dest), allocator)
	}
	write :: proc(x: ^Custom_Of, v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
		c, kind := (proc(t: ^T, allocator: runtime.Allocator) -> (C, core.Typed_Error_Kind))(x.to)((^T)(v), allocator)
		return stand_in(c, allocator, kind)
	}
	_, err := append(&reg.customs, Custom_Of{T, C, rawptr(custom.from), rawptr(custom.to), read, write, {}})
	return err
}

// A model's copy of `reg`'s customs, and the hooks of the carriers and then of the customs, for `reads`.
@(private)
carriers_of :: proc(reg: ^Registry, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (customs: []Custom_Of, hooks: []typed.Type_Hook, err: core.Error) {
	if reads == nil || reads.plan == nil {
		return
	}
	if reg != nil {
		customs = slice.clone(reg.customs[:], allocator) or_return
	}
	list := make([dynamic]typed.Type_Hook, 0, len(CARRIERS) + len(customs), allocator) or_return
	for c in CARRIERS {
		if c.hook.type != nil {
			append(&list, c.hook)
		}
	}
	read :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
		x := (^Custom_Of)(context.user_ptr)
		return x.read(x, transmute([]u8)v.text, dest, allocator)
	}
	write :: proc(v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
		x := (^Custom_Of)(context.user_ptr)
		return x.write(x, v, allocator)
	}
	for &x in customs {
		append(&list, typed.Type_Hook{x.type, read, write, &x, x.carrier})
	}
	return customs, list[:], nil
}

// Compiles the carrier plan of each custom `m`'s plans use, with the hooks of the carriers. A carrier `reads` makes no plan
// for refuses the model as that plan is refused, with the custom's type as `want.type`.
@(private)
carrier_plans :: proc(m: ^Model($T), reads: ^typed.Format_Reads, carriers: []typed.Type_Hook, allocator: runtime.Allocator) -> core.Error {
	uses :: proc(p: ^typed.Plan, x: rawptr) -> bool {
		for &r in p.extra {
			if r.data == x {
				return true
			}
		}
		return false
	}
	for &x in m.customs {
		if uses(&m.plan, &x) || uses(&m.load_plan, &x) {
			refused: core.Typed_Refusal
			if x.plan, refused = reads.plan(x.carrier, {hooks = carriers}, allocator); refused.kind != .None {
				refused.want.type = x.type
				return core.error_of(refused)
			}
		}
	}
	return nil
}

@(private)
uuid_read :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	id, err := uuid.read(v.decoded)
	if v.kind != .String || err != nil {
		return .Wrong_Kind if v.kind != .String else .Bad_Format
	}
	(^uuid.Identifier)(dest)^ = id
	return nil
}

@(private)
uuid_write :: proc(v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
	text, err := uuid.to_string((^uuid.Identifier)(v)^, allocator)
	return stand_in(text, allocator, .None if err == nil else .No_Memory)
}

@(private)
base64_read :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	if v.kind != .String {
		return .Wrong_Kind
	}
	bytes, err := base64.decode(v.decoded, allocator = allocator)
	if _, no_memory := err.(runtime.Allocator_Error); no_memory {
		return .No_Memory
	} else if err != nil {
		return .Bad_Format
	}
	(^Base64)(dest)^ = Base64(bytes)
	return nil
}

@(private)
base64_write :: proc(v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
	text, err := base64.encode(([]u8)((^Base64)(v)^), allocator = allocator)
	return stand_in(text, allocator, .None if err == nil else .No_Memory)
}

@(private)
decimal_read :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	if v.kind != .Number && v.kind != .String {
		return .Wrong_Kind
	}
	text, err := strings.clone(v.decoded, allocator)
	if err != nil {
		return .No_Memory
	}
	(^Decimal)(dest)^ = {text, core.text_f64(text)}
	return nil
}

@(private)
decimal_write :: proc(v: rawptr, allocator: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
	n := core.Number_Text((^Decimal)(v)^)
	// The zero value is zero, where a `core.Number_Text`'s writes null.
	n.text = n.text if n.text != "" else "0"
	return stand_in(n, allocator, .None)
}

// `v` as a write's stand-in, refused as `kind` when that is not `.None`.
@(private)
stand_in :: proc(v: $V, allocator: runtime.Allocator, kind: core.Typed_Error_Kind) -> (any, core.Typed_Error_Kind) {
	held := new_clone(v, allocator) or_else nil
	return any{held, typeid_of(V)}, .No_Memory if held == nil && kind == .None else kind
}
