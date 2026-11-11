package model

import "core:reflect"
import core ".."
import typed "../typed"
import records "../records"

// Reads `src` into `v` by the model's rules, and reports every rule a value fails, not only the first. `v` is zeroed
// first, so a member the text leaves out holds its default or its zero. A read_only member is neither read nor judged,
// and a write_only one is read. A key the struct does not name is skipped unless the struct forbids it, and a key the
// text repeats anywhere, inside a skipped value too, ends the load as `.Duplicate_Key` unless `dups` says which one
// wins, as `opts` says. Strings and the other values the text builds are allocated with `allocator`. Every refusal goes
// to `sink` as a `core.Error_Entry` with its path, up to the sink's limit, and with no sink the first ends the read.
// Returns the first.
load :: proc(m: ^Model($T), src: []u8, v: ^T, sink: ^typed.Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> core.Error {
	return typed.check_text(src, v, T, &m.load_plan, read_options(&m.load_plan, opts, sink), allocator)
}

// How a load reads. `dups` says which of a repeated key's values wins, `.Last` or `.First`. Its zero, `.Default`, refuses
// a repeat, where `json.unmarshal`'s zero takes the last, since a load reads a request whose repeat is a mistake.
// `.All` is `.Bad_Option`, since a member holds one value.
Load_Opts :: struct {
	dups: core.Duplicates,
}

// The check read of `opts`. A repeat a read does not refuse is noticed, so the value that wins is the one judged, and a
// flat format, whose read sees no repeat, ignores it.
@(private)
read_options :: proc(plan: ^typed.Plan, opts: Load_Opts, sink: ^typed.Sink) -> typed.Read_Options {
	flat := plan.as.readers != nil && plan.as.readers.flat
	return {dups = .Refuse if opts.dups == .Default else opts.dups, sink = sink, repeats = .Ignore if flat else .Notice}
}

// Loads the value `v` as `load` loads the text of the model's format that spells it, so a value built in memory is judged
// and defaulted as a read of it would be. The offsets in the entries are from the start of that text. A format whose plan
// writes no value text is `.Bad_Option`.
load_value :: proc(m: ^Model($T), v: core.Value, out: ^T, sink: ^typed.Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> core.Error {
	if m.load_plan.value_text == nil {
		return core.error_of(core.Typed_Refusal{kind = .Bad_Option})
	}
	text, err := m.load_plan.value_text(&m.load_plan, v, context.allocator)
	defer delete(text)
	if err.kind != .None {
		return core.error_of(err)
	}
	return typed.check_text(text, out, T, &m.load_plan, read_options(&m.load_plan, opts, sink), allocator)
}

// Whether the load that filled `set`, a member of a struct of type `S` in `T`, read the member `S` declares as `name`, by
// the name Odin gives it and not the format's alias. A read_only member is never read. Asserts that `S` has a member
// `name`.
was_set :: proc(m: ^Model($T), $S: typeid, set: Fields_Set, name: string) -> bool {
	return set_holds(&m.load_plan, S, set, name)
}

@(private)
set_holds :: proc(plan: ^typed.Plan, S: typeid, set: Fields_Set, name: string) -> bool {
	member := reflect.struct_field_by_name(S, name)
	assert(len(name) > 0 && member.name == name, "was_set: the struct has no member of that name")
	for x in plan.meta {
		if x.type != S || x.members == 0 || x.list {
			continue
		}
		for i in 0 ..< x.members {
			if uintptr(plan.fields[x.block + i].offset) == member.offset {
				return set.bits[i / 64] >> uint(i % 64) & 1 != 0
			}
		}
		return false
	}
	return false
}

// Loads the next record of `it` into `v` as `load` loads a text of one record, and returns whether `it` has more, by the
// check read the model's load plan holds. The records may be of a stream, and each is judged and defaulted alone: a
// header is judged with the first record of a table. A refused record returns its error and true, and the next call goes
// on after it. Every offset is from the input's first byte.
read :: proc(it: ^records.Reader, m: ^Model($T), v: ^T, sink: ^typed.Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> (err: core.Error, more: bool) {
	from := len(sink.entries) if sink != nil else 0
	err, more = records.read(it, v, &m.load_plan, read_options(&m.load_plan, opts, sink), allocator)
	typed.order_entries(sink, from)
	return
}
