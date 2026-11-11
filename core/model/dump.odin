package model

import "base:runtime"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import core ".."
import typed "../typed"
import write "../write"

// What a dump leaves out besides the write_only members, which it never writes. Each option leaves out only a member a
// load does not require, so every dump of a valid value loads back. `exclude_unset` leaves out a member that its
// struct's `Fields_Set` does not hold, in a struct that has one: what a load took from a default or never read, and
// every such member of a value built in memory whose set is empty. A read_only member, which no load sets, and the
// members of a struct with no set are kept. `exclude_none` leaves out a member that holds null: a nil `Maybe`, pointer,
// union, `any` or cstring. `exclude_defaults` leaves out a member that equals its default, its zero where it has none.
// A CSV or TSV row keeps every column and an empty cell reads back as null, so there the options leave nothing out: a
// member that holds null is an empty cell, and every other member's value is written. `check` validates
// what the dump writes first, and a value that fails is `.Check_Failed` and writes nothing.
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
	return dump_to(&m.plan, m.judging, v, opts, write, {}, sink, allocator)
}

// `dump` to `w`, as the text is made. On a refusal of the write `w` may hold a prefix of the text.
dump_stream :: proc(w: io.Stream, m: ^Model($T), v: ^T, opts := Dump_Opts{}, write := core.Write_Options{}, sink: ^typed.Sink = nil) -> core.Error {
	_, err := dump_to(&m.plan, m.judging, v, opts, write, w, sink, context.allocator)
	return err
}

@(private)
dump_to :: proc(plan: ^typed.Plan, judging: ^Applied, v: rawptr, opts: Dump_Opts, write: core.Write_Options, stream: io.Stream, sink: ^typed.Sink, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	if plan.marshal == nil {
		return nil, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	d := Dumping{omits = {call = omitted}, opts = opts, plan = plan}
	defer virtual.arena_destroy(&d.defaults)
	flat := plan.as.readers != nil && plan.as.readers.flat
	omits := &d.omits if !flat && (opts.exclude_unset || opts.exclude_none || opts.exclude_defaults) else nil
	if opts.check {
		err := validate_value(plan, v, sink, judging, omits)
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
	x := typed.extra_at(plan, r.meta)
	if !x.optional {
		return false
	}
	if d.opts.exclude_none && write.holds_null(m, r.kind, at) || d.opts.exclude_unset && write.unset(x, r, at) {
		return true
	}
	if !d.opts.exclude_defaults {
		return false
	}
	held := default_of(d, m, x)
	return held != nil && equal_values(rawptr(at), held, type_info_of(m.type))
}

// The default of the member of meta `m`, made once a dump, or a zeroed block for a member with none. Nil when memory ran
// out, which keeps the member.
@(private)
default_of :: proc(d: ^Dumping, m: ^typed.Meta, e: ^typed.Meta_Extra) -> rawptr {
	size := type_info_of(m.type).size
	memory := virtual.arena_allocator(&d.defaults)
	if e.default == 0 {
		if len(d.zero) < size {
			d.zero = make([]u8, size, memory)
		}
		return raw_data(d.zero) if len(d.zero) >= size else nil
	}
	x := &e.owner.defaults[e.default - 1]
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
