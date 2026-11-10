package schema

import "core:mem/virtual"
import "core:strconv"
import "core:slice"
import "core:strings"
import core "../"
import "../rules"

// The search for a value one description takes and another refuses. Values are built from the structure of the first,
// with the numbers, lengths and names either description mentions as the values to try, and the check of both
// descriptions is the only judge of a candidate.

@(private = "file")
MAX_CANDIDATES :: 12

@(private = "file")
MAX_DEPTH :: 5

// The values one search may build in all. Every candidate list counts its length and every call counts one, so the
// nesting of arrays and objects cannot multiply into work or memory beyond it.
@(private = "file")
MAX_BUILT :: 20_000

// The enum values, and the named members, one search follows. A description with more is searched in part, and a search
// that found nothing then says so.
@(private = "file")
MAX_LISTED :: 256

// The arrays of one length that one search builds from the values its items may take.
@(private = "file")
ARRAY_VARIANTS :: 6

// The longest list of one kind of hint.
@(private = "file")
MAX_HINTS :: 48

@(private = "file")
Hints :: struct {
	numbers: [dynamic]f64,
	counts:  [dynamic]int,
	names:   [dynamic]string,
	strings: [dynamic]string,
}

@(private = "file")
Search :: struct {
	from, to: ^Side,
	hints:    Hints,
	budget:   int,
	// Where the text of a candidate and what its check allocates go, which is freed after each candidate.
	texts:    virtual.Arena,
	// A list was cut at `MAX_LISTED`, so an empty result is no proof that none exists.
	cut:      bool,
}

// A value that `from` takes and `to` refuses, as text, confirmed by the check of both.
@(private)
refute :: proc(from, to: ^Side) -> (text: string, found, exhausted: bool) {
	s := Search {
		from  = from,
		to    = to,
		budget = MAX_BUILT,
		hints = {
			numbers = make([dynamic]f64, context.temp_allocator),
			counts = make([dynamic]int, context.temp_allocator),
			names = make([dynamic]string, context.temp_allocator),
			strings = make([dynamic]string, context.temp_allocator),
		},
	}
	_ = virtual.arena_init_growing(&s.texts)
	defer virtual.arena_destroy(&s.texts)
	append(&s.hints.numbers, 0, 1, -1, 0.5, 1.5, 2, 1e9)
	append(&s.hints.counts, 0, 1, 2)
	append(&s.hints.strings, "", "a", "ab")
	for d in ([2]^rules.Description{from.d, to.d}) {
		gather(&s.hints, d)
	}
	trim(&s.hints)
	for v in candidates(&s, {from.d.root}, 0) {
		kept := context.temp_allocator
		context.temp_allocator = virtual.arena_allocator(&s.texts)
		bytes, ok := text_of(from, v)
		if ok {
			taken, known := accepts(from, {from.d.root}, bytes)
			refused, judged := accepts(to, {to.d.root}, bytes)
			if taken && known && !refused && judged {
				return strings.clone(string(bytes), kept), true, false
			}
		}
		context.temp_allocator = kept
		virtual.arena_free_all(&s.texts)
	}
	return "", false, s.budget <= 0 || s.cut
}

@(private = "file")
gather :: proc(h: ^Hints, d: ^rules.Description) {
	number :: proc(h: ^Hints, text: string) {
		x, ok := strconv.parse_f64(text)
		if text != "" && ok {
			append(&h.numbers, x, x + 1, x - 1, x * 2, x / 2)
		}
	}
	for n in d.nodes {
		r := n.rules
		number(h, r.minimum)
		number(h, r.maximum)
		number(h, r.multiple_of)
		for c in ([?]u64{r.min_items, r.min_length, r.min_members, r.max_items.? or_else 0, r.max_length.? or_else 0, r.max_members.? or_else 0}) {
			append(&h.counts, int(c), int(c) + 1)
		}
		if r.min_length > 0 || r.max_length != nil {
			for c in ([?]u64{r.min_length, r.min_length + 1, r.max_length.? or_else 0, (r.max_length.? or_else 0) + 1}) {
				append(&h.strings, strings.repeat("a", int(min(c, 64)), context.temp_allocator))
			}
		}
		// A pattern with no operators in it is the text it matches.
		if literal := strings.trim_suffix(strings.trim_prefix(r.pattern, "^"), "$"); r.pattern != "" && !strings.contains_any(literal, "^$.[]()*+?{}|\\") {
			append(&h.strings, literal)
		}
		for v in n.enum_of {
			if t, is_text := v.(string); is_text {
				append(&h.strings, t)
			}
		}
	}
	for o in d.objects {
		for m in o.members {
			append(&h.names, m.name)
		}
	}
}

// Each hint once, in order of first mention, and no more than `MAX_HINTS` of a kind.
@(private = "file")
trim :: proc(h: ^Hints) {
	once :: proc(list: ^[dynamic]$T) {
		kept := 0
		for x in list^ {
			if !slice.contains(list[:kept], x) {
				list[kept] = x
				kept += 1
			}
		}
		resize(list, min(kept, MAX_HINTS))
	}
	once(&h.numbers)
	once(&h.names)
	once(&h.strings)
	slice.sort(h.counts[:])
	once(&h.counts)
}

// Values `nodes` of `s.from` may take, with room for a failing one among them. The ones a node cannot take are left out
// by the caller's check, not here.
@(private = "file")
candidates :: proc(s: ^Search, nodes: []rules.Node_Index, depth: int) -> []core.Value {
	out := make([dynamic]core.Value, context.temp_allocator)
	s.budget -= 1
	if s.budget <= 0 {
		return nil
	}
	defer s.budget -= len(out)
	bs, fits := branches(s.from.d, nodes)
	if !fits {
		return nil
	}
	for ab in bs {
		an := nodes_of(s.from.d, ab[:])
		kinds := kinds_of(an)
		for n in an {
			if n.has_enum || n.const_of != nil {
				listed := n.enum_of[:min(len(n.enum_of), MAX_LISTED)]
				s.cut ||= len(listed) < len(n.enum_of)
				append(&out, ..listed)
				if c, has := n.const_of.?; has {
					append(&out, c)
				}
				kinds = {}
				break
			}
		}
		if kinds & {.Null} != {} {
			append(&out, nil)
		}
		if .Bool in kinds {
			append(&out, false, true)
		}
		if kinds & {.Integer, .Number} != {} {
			for x in s.hints.numbers {
				append(&out, x)
			}
		}
		if .String in kinds {
			for t in s.hints.strings {
				append(&out, t)
			}
		}
		// A value with no node to shape it nests nothing deeper than empty.
		if len(an) == 0 {
			append(&out, new(core.Array, context.temp_allocator), new(core.Object, context.temp_allocator))
		} else if depth < MAX_DEPTH {
			if .Array in kinds {
				append(&out, ..arrays(s, an, depth))
			}
			if .Object in kinds {
				append(&out, ..objects(s, an, depth))
			}
		}
	}
	return out[:]
}

// The first few values of `nodes` that the check of `s.from` takes.
@(private = "file")
fitting :: proc(s: ^Search, nodes: []rules.Node_Index, depth: int) -> []core.Value {
	out := make([dynamic]core.Value, context.temp_allocator)
	for v in candidates(s, nodes, depth) {
		if len(out) == MAX_CANDIDATES {
			break
		}
		kept := context.temp_allocator
		context.temp_allocator = virtual.arena_allocator(&s.texts)
		if bytes, ok := text_of(s.from, v); ok {
			if taken, known := accepts(s.from, nodes, bytes); taken && known {
				append(&out, v)
			}
		}
		context.temp_allocator = kept
		virtual.arena_free_all(&s.texts)
	}
	return out[:]
}

@(private = "file")
arrays :: proc(s: ^Search, an: []^rules.Node, depth: int) -> []core.Value {
	blocks := make([dynamic]^rules.Array, context.temp_allocator)
	for n in an {
		if n.array >= 0 {
			append(&blocks, &s.from.d.arrays[n.array])
		}
	}
	out := make([dynamic]core.Value, context.temp_allocator)
	for count in s.hints.counts {
		if count > 6 {
			continue
		}
		per_item := make([][]core.Value, count, context.temp_allocator)
		for i in 0 ..< count {
			have := make([dynamic]rules.Node_Index, context.temp_allocator)
			for blk in blocks {
				if e := blk.prefix[i] if i < len(blk.prefix) else blk.items; e != rules.NONE {
					append(&have, e)
				}
			}
			per_item[i] = fitting(s, have[:], depth + 1)
		}
		// Variant 1 takes distinct values, which a unique array needs, and each of the others repeats one value.
		for variant in 0 ..< ARRAY_VARIANTS {
			items := new(core.Array, context.temp_allocator)
			items.items = make([dynamic]core.Value, context.temp_allocator)
			for picks, i in per_item {
				switch {
				case len(picks) == 0:
					append(&items.items, nil)
				case variant == 1:
					append(&items.items, picks[i % len(picks)])
				case:
					append(&items.items, picks[max(variant - 1, 0) % len(picks)])
				}
			}
			s.budget -= len(items.items)
			append(&out, items)
		}
	}
	return out[:]
}

@(private = "file")
objects :: proc(s: ^Search, an: []^rules.Node, depth: int) -> []core.Value {
	blocks := make([dynamic]^rules.Object, context.temp_allocator)
	for n in an {
		if n.object >= 0 {
			append(&blocks, &s.from.d.objects[n.object])
		}
	}
	names := make([dynamic]string, context.temp_allocator)
	for blk in blocks {
		for m in blk.members {
			if !slice.contains(names[:], m.name) {
				append(&names, m.name)
			}
		}
	}
	required := make([dynamic]string, context.temp_allocator)
	for name in names {
		if required_in(blocks[:], name) {
			append(&required, name)
		}
	}
	// Past the limit the object cannot be built whole, and one that leaves a member out is no witness for a schema
	// that requires it.
	s.cut ||= len(names) > MAX_LISTED
	resize(&names, min(len(names), MAX_LISTED))
	s.cut ||= len(required) > MAX_LISTED
	resize(&required, min(len(required), MAX_LISTED))
	for name in s.hints.names {
		if !slice.contains(names[:], name) {
			append(&names, name)
		}
	}
	append(&names, "zz")
	base := make([dynamic]Member_Value, context.temp_allocator)
	for name in required {
		if picks := fitting(s, member_nodes(blocks[:], name), depth + 1); len(picks) > 0 {
			append(&base, Member_Value{name, picks[0]})
		}
	}
	out := make([dynamic]core.Value, context.temp_allocator)
	append(&out, object_with(base[:], ""))
	for name in names {
		picks := fitting(s, member_nodes(blocks[:], name), depth + 1)
		for v in picks[:min(4, len(picks))] {
			o := object_with(base[:], name, v)
			s.budget -= len(o.keys)
			append(&out, o)
		}
	}
	return out[:]
}

@(private = "file")
Member_Value :: struct {
	name:  string,
	value: core.Value,
}

// An object of `base` with the member `name` set to `value`, none when `name` is "".
@(private = "file")
object_with :: proc(base: []Member_Value, name: string, value: core.Value = nil) -> ^core.Object {
	o := new(core.Object, context.temp_allocator)
	o.keys = make([dynamic]string, context.temp_allocator)
	o.vals = make([dynamic]core.Value, context.temp_allocator)
	for m in base {
		if m.name != name {
			append(&o.keys, m.name)
			append(&o.vals, m.value)
		}
	}
	if name != "" {
		append(&o.keys, name)
		append(&o.vals, value)
	}
	return o
}
