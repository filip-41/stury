package model

import "base:runtime"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import core ".."
import typed "../typed"
import write "../write"

// What a dump leaves out besides the write_only members, which it never writes. `exclude_unset` leaves out a member
// its struct's `Fields_Set` does not hold, in a struct that has one. `exclude_none` leaves out a member that holds null:
// a nil `Maybe`, pointer, union, `any` or cstring, a required one too, so the text may not load back. `exclude_defaults`
// leaves out a member that is not required and equals its default, its zero where it has none. `check` validates what
// the dump writes first, and a value that fails is `.Check_Failed` and writes nothing.
Dump_Opts :: struct {
	exclude_unset:    bool,
	exclude_none:     bool,
	exclude_defaults: bool,
	check:            bool,
}

// Writes `v` in the model's format, as `marshal` writes it by the model's plan, with what `opts` leaves out, into new
// bytes from `allocator`. A map's keys are written in order, and a struct's `extra` members after its own, in the order
// of their keys. Under `check`, every failure `validate` finds in what is written goes to `sink`, and the returned
// `.Check_Failed` has the first's path and its code as `want.text`, the sink alone its message.
dump :: proc(m: ^Model($T), v: ^T, opts := Dump_Opts{}, write := core.Write_Options{}, sink: ^typed.Sink = nil, allocator := context.allocator) -> ([]u8, core.Error) {
	return dump_to(&m.plan, v, opts, write, {}, sink, allocator)
}

// `dump` to `w`, as the text is made. On a refusal of the write `w` may hold a prefix of the text.
dump_stream :: proc(w: io.Stream, m: ^Model($T), v: ^T, opts := Dump_Opts{}, write := core.Write_Options{}, sink: ^typed.Sink = nil) -> core.Error {
	_, err := dump_to(&m.plan, v, opts, write, w, sink, context.allocator)
	return err
}

@(private)
dump_to :: proc(plan: ^typed.Plan, v: rawptr, opts: Dump_Opts, write: core.Write_Options, stream: io.Stream, sink: ^typed.Sink, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	if plan.marshal == nil {
		return nil, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	d := Dumping{omits = {call = omitted}, opts = opts, plan = plan}
	defer virtual.arena_destroy(&d.defaults)
	omits := &d.omits if opts.exclude_unset || opts.exclude_none || opts.exclude_defaults else nil
	if opts.check {
		err := validate_value(plan, v, sink, omits)
		if f, failed := err.(core.Typed_Error); failed {
			f.want = {text = core.entry_code({kind = f.kind})}
			f.kind = .Check_Failed
			return nil, f
		}
		if err != nil {
			return nil, err
		}
	}
	text, err := plan.marshal(plan, v, write, stream, allocator, omits)
	return text, core.error_of(err)
}

// The `Omits` of a dump, and the defaults it has made to compare with, each once, in `defaults`.
@(private)
Dumping :: struct {
	using omits: typed.Omits,
	opts:        Dump_Opts,
	plan:        ^typed.Plan,
	defaults:    virtual.Arena,
	made:        map[rawptr]rawptr,
	zero:        []u8,
}

// Whether the dump's options leave out the member of record `r` at `at`. A side plan's member, an `any`'s, is not the
// model's and only its tag's `omitempty` leaves it out.
@(private)
omitted :: proc(o: ^typed.Omits, plan: ^typed.Plan, r: ^typed.Field, at: uintptr) -> bool {
	d := (^Dumping)(o)
	m := &plan.meta[r.meta]
	if plan != d.plan {
		return false
	}
	if d.opts.exclude_none && write.holds_null(m, r.kind, at) {
		return true
	}
	if sm := m.owner; d.opts.exclude_unset && sm != nil && sm.fields_set != 0 && m.bit >= 0 {
		set := (^Fields_Set)(at - uintptr(r.offset) + uintptr(sm.fields_set - 1))
		if set.bits[m.bit / 64] >> uint(m.bit % 64) & 1 == 0 {
			return true
		}
	}
	if !d.opts.exclude_defaults || !m.optional {
		return false
	}
	held := default_of(d, m)
	return held != nil && equal(rawptr(at), held, type_info_of(m.type))
}

// The default of the member of meta `m`, made once a dump, or a zeroed block for a member with none. Nil when memory ran
// out, which keeps the member.
@(private)
default_of :: proc(d: ^Dumping, m: ^typed.Meta) -> rawptr {
	size := type_info_of(m.type).size
	memory := virtual.arena_allocator(&d.defaults)
	if m.default == 0 {
		if len(d.zero) < size {
			d.zero = make([]u8, size, memory)
		}
		return raw_data(d.zero) if len(d.zero) >= size else nil
	}
	x := &m.owner.defaults[m.default - 1]
	if held, found := d.made[x]; found {
		return held
	}
	if d.made == nil {
		d.made = make(map[rawptr]rawptr, memory)
	}
	held, err := mem.alloc(size, type_info_of(m.type).align, memory)
	if err != nil || x.make(held, x.data, memory) != nil {
		return nil
	}
	d.made[x] = held
	return held
}

// Whether the values of type `ti` at `a` and `b` are equal: strings, lists, maps, pointers' targets and unions by what
// they hold, and the rest, floats among them, by their bytes.
@(private)
equal :: proc(a, b: rawptr, ti: ^runtime.Type_Info) -> bool {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_String:
		if v.is_cstring {
			return string((^cstring)(a)^) == string((^cstring)(b)^) && ((^cstring)(a)^ == nil) == ((^cstring)(b)^ == nil)
		}
		return (^string)(a)^ == (^string)(b)^
	case runtime.Type_Info_Slice:
		x, y := (^runtime.Raw_Slice)(a)^, (^runtime.Raw_Slice)(b)^
		return x.len == y.len && equal_elements(x.data, y.data, x.len, v.elem)
	case runtime.Type_Info_Dynamic_Array:
		x, y := (^runtime.Raw_Dynamic_Array)(a)^, (^runtime.Raw_Dynamic_Array)(b)^
		return x.len == y.len && equal_elements(x.data, y.data, x.len, v.elem)
	case runtime.Type_Info_Array:
		return equal_elements(a, b, v.count, v.elem)
	case runtime.Type_Info_Struct:
		if .raw_union in v.flags {
			break
		}
		for i in 0 ..< int(v.field_count) {
			if !equal(rawptr(uintptr(a) + v.offsets[i]), rawptr(uintptr(b) + v.offsets[i]), v.types[i]) {
				return false
			}
		}
		return true
	case runtime.Type_Info_Pointer:
		x, y := (^rawptr)(a)^, (^rawptr)(b)^
		return x == y || x != nil && y != nil && equal(x, y, v.elem)
	case runtime.Type_Info_Union:
		x, y := reflect.get_union_variant_raw_tag(any{a, ti.id}), reflect.get_union_variant_raw_tag(any{b, ti.id})
		if x != y {
			return false
		}
		variant := reflect.get_union_variant(any{a, ti.id})
		return variant.id == nil || equal(a, b, type_info_of(variant.id))
	case runtime.Type_Info_Map:
		x, y := (^runtime.Raw_Map)(a), (^runtime.Raw_Map)(b)
		if x.len != y.len {
			return false
		}
		it := 0
		for k, value in reflect.iterate_map(any{a, ti.id}, &it) {
			hash := v.map_info.key_hasher(k.data, runtime.map_seed(y^))
			found := runtime.__dynamic_map_get(y, v.map_info, hash, k.data)
			if found == nil || !equal(value.data, found, v.value) {
				return false
			}
		}
		return true
	}
	return mem.compare_ptrs(a, b, base.size) == 0
}

@(private)
equal_elements :: proc(a, b: rawptr, n: int, elem: ^runtime.Type_Info) -> bool {
	for i in 0 ..< n {
		if !equal(rawptr(uintptr(a) + uintptr(i * elem.size)), rawptr(uintptr(b) + uintptr(i * elem.size)), elem) {
			return false
		}
	}
	return true
}
