package schema

import "core:mem/virtual"
import "core:strconv"
import "core:slice"
import "core:strings"
import "../regex"
import core "../"
import "../rules"

// The search for a value one description takes and another refuses. Values are built from the structure of the first,
// with the numbers, lengths and names either description mentions as the values to try, and the check of both
// descriptions is the only judge of a candidate.

@(private = "file") MAX_CANDIDATES :: 12
@(private = "file") MAX_DEPTH :: 5
@(private = "file") MAX_BUILT :: 20_000 // Values one search builds in all, each list counting its length
@(private = "file") MAX_LISTED :: 256 // Enum values and named members one search follows
@(private = "file") ARRAY_VARIANTS :: 6 // Arrays of one length built from the values the items may take
@(private = "file") MAX_HINTS :: 48 // Longest list of one kind of hint
@(private = "file") PATTERN_SAMPLES :: 3 // Texts drawn from each pattern
@(private = "file") MAX_PLACED :: 4 // Values found at a place a proof stopped at
@(private = "file") MAX_OUTER :: 64 // Values of the whole each placed value is set into
@(private = "file") MAX_PREFIX_PLACED :: 64 // Furthest element a witness is set at

// The name of a member no description names.
@(private)
OTHER_NAME :: "zz"

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

// A value that `from` takes and `to` refuses, as text, confirmed by the check of both. The search first sets values
// found at each of `foci` into values of the whole, and then tries the values of the whole alone.
@(private)
refute :: proc(from, to: ^Side, foci: []Focus) -> (text: string, found, exhausted: bool) {
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
	// The checks of the roots are bound first, so that those of the places cannot take their room.
	judge_of(from, from.d.root)
	judge_of(to, to.d.root)
	whole := candidates(&s, {from.d.root}, 0)
	flat := from.as.readers != nil && from.as.readers.flat
	for f in foci {
		if flat {
			break
		}
		for w in found_at(&s, f) {
			for i in -1 ..< min(len(whole), MAX_OUTER) {
				outer: core.Value
				if i >= 0 {
					outer = whole[i]
				}
				if text, found = confirmed(&s, {from.d.root}, {to.d.root}, placed(outer, f.path, w)); found {
					return text, true, false
				}
			}
		}
	}
	for v in whole {
		if text, found = confirmed(&s, {from.d.root}, {to.d.root}, v); found {
			return text, true, false
		}
	}
	return "", false, s.budget <= 0 || s.cut
}

// The text of `v` when the conjunction `a` of `s.from` takes it and `b` of `s.to` refuses it, in the temp allocator.
@(private = "file")
confirmed :: proc(s: ^Search, a, b: []rules.Node_Index, v: core.Value) -> (text: string, found: bool) {
	kept := context.temp_allocator
	context.temp_allocator = virtual.arena_allocator(&s.texts)
	defer {
		context.temp_allocator = kept
		virtual.arena_free_all(&s.texts)
	}
	bytes := text_of(s.from, v) or_return
	taken, known := accepts(s.from, a, bytes)
	refused, judged := accepts(s.to, b, bytes)
	if taken && known && !refused && judged {
		return strings.clone(string(bytes), kept), true
	}
	return "", false
}

// Values that the conjunction `f.a` of `s.from` takes and `f.b` of `s.to` refuses.
@(private = "file")
found_at :: proc(s: ^Search, f: Focus) -> []core.Value {
	out := make([dynamic]core.Value, context.temp_allocator)
	for v in candidates(s, f.a, min(len(f.path), MAX_DEPTH)) {
		if len(out) == MAX_PLACED || s.budget <= 0 {
			break
		}
		if _, found := confirmed(s, f.a, f.b, v); found {
			append(&out, v)
		}
	}
	return out[:]
}

// `v` with the value at `path` replaced by `w`, a short array filled up to the element with it.
@(private = "file")
placed :: proc(v: core.Value, path: []core.Step, w: core.Value) -> core.Value {
	if len(path) == 0 {
		return w
	}
	#partial switch step in path[0] {
	case core.Name:
		base := make([dynamic]Member_Value, context.temp_allocator)
		inner: core.Value
		if o, is_object := v.(^core.Object); is_object {
			for key, i in o.slot_keys {
				if key == string(step) {
					inner = o.slot_vals[i]
				}
				append(&base, Member_Value{key, o.slot_vals[i]})
			}
		}
		return object_with(base[:], string(step), placed(inner, path[1:], w))
	case core.Index:
		at := int(step)
		if at > MAX_PREFIX_PLACED {
			return v
		}
		items := new(core.Array, context.temp_allocator)
		items.items = make([dynamic]core.Value, context.temp_allocator)
		if a, is_array := v.(^core.Array); is_array {
			append(&items.items, ..a.items[:])
		}
		for len(items.items) <= at {
			append(&items.items, placed(nil, path[1:], w))
		}
		items.items[at] = placed(items.items[at], path[1:], w)
		return items
	}
	return v
}

// A name the pattern `expression` matches, or `OTHER_NAME` where none is drawn.
@(private)
name_of_pattern :: proc(expression: string) -> string {
	drawn := make([dynamic]string, context.temp_allocator)
	samples(&drawn, expression)
	return drawn[0] if len(drawn) > 0 else OTHER_NAME
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
			// A count past what a witness builds stays a count `arrays` skips, not one that wraps negative.
			n := int(min(c, 1 << 20))
			append(&h.counts, n, n + 1)
		}
		if r.min_length > 0 || r.max_length != nil {
			for c in ([?]u64{r.min_length, r.min_length + 1, r.max_length.? or_else 0, (r.max_length.? or_else 0) + 1}) {
				append(&h.strings, strings.repeat("a", int(min(c, 64)), context.temp_allocator))
			}
		}
		for v in n.enum_of {
			text_hint(h, v)
		}
		if c, has := n.const_of.?; has {
			text_hint(h, c)
		}
		samples(&h.strings, r.pattern)
		// A text of the grammar of a format is what tells one format from another.
		if sample := format_sample(r.format); r.format != "" && sample != "" {
			append(&h.strings, sample)
		}
	}
	for o in d.objects {
		for m in o.members {
			append(&h.names, m.name)
		}
		for q in o.patterns {
			samples(&h.names, q.expression)
		}
	}
	for a in d.arrays {
		append(&h.counts, len(a.prefix), len(a.prefix) + 1)
	}
}

// Appends the text of `v` to the strings of `h` where `v` is a string.
@(private = "file")
text_hint :: proc(h: ^Hints, v: core.Value) {
	if core.kind(v) != .String {
		return
	}
	buf: [256]u8
	if t, ok := core.text(v, buf[:]); ok {
		append(&h.strings, strings.clone(t, context.temp_allocator))
	}
}

// Appends to `out` texts the pattern `expression` may match, drawn the same each time.
@(private = "file")
samples :: proc(out: ^[dynamic]string, expression: string) {
	if expression == "" {
		return
	}
	context.allocator = context.temp_allocator
	src := regex.Source{state = 1}
	for _ in 0 ..< PATTERN_SAMPLES {
		if text, ok := regex.sample(expression, &src, 2, 1); ok {
			append(out, text)
		}
	}
}

// Each hint once, in order of first mention, and no more than `MAX_HINTS` of a kind.
@(private = "file")
trim :: proc(h: ^Hints) {
	once :: proc(list: ^[dynamic]$T) {
		kept := 0
		for x in list^ {
			if kept == MAX_HINTS {
				break
			}
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
	bs, fits := rules.branches(s.from.d, nodes, true, MAX_BRANCHES)
	if !fits {
		bs, fits = rules.branches(s.from.d, nodes, false, MAX_BRANCHES)
	}
	if !fits {
		return nil
	}
	for ab in bs {
		an := nodes_of(s.from.d, ab[:])
		kinds := rules.kinds_of(s.from.d, ab[:])
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

// The first few values of `nodes` that the check of `s.from` takes. A flat format cannot spell a sub-value, a cell or a
// row, as a text of its own, so there the candidates stand unjudged and the check of the whole table decides.
@(private = "file")
fitting :: proc(s: ^Search, nodes: []rules.Node_Index, depth: int) -> []core.Value {
	out := make([dynamic]core.Value, context.temp_allocator)
	flat := s.from.as.readers != nil && s.from.as.readers.flat
	for v in candidates(s, nodes, depth) {
		if len(out) == MAX_CANDIDATES {
			break
		}
		if flat {
			append(&out, v)
			continue
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
	blocks := object_blocks(s.from.d, an)
	names := make([dynamic]string, context.temp_allocator)
	// The place of each name in `names`, -1 for a hint's.
	listed := make(map[string]int, context.temp_allocator)
	for blk in blocks {
		for m in blk.members {
			if m.name not_in listed {
				listed[m.name] = len(names)
				append(&names, m.name)
			}
		}
	}
	named := names_of_blocks(blocks[:])
	required := make([dynamic]string, context.temp_allocator)
	for name in names {
		if required_in(blocks[:], named, name) {
			append(&required, name)
		}
	}
	// Past the limit the object cannot be built whole, and one that leaves a member out is no witness for a schema
	// that requires it.
	s.cut ||= len(names) > MAX_LISTED
	resize(&names, min(len(names), MAX_LISTED))
	s.cut ||= len(required) > MAX_LISTED
	resize(&required, min(len(required), MAX_LISTED))
	kept := len(names)
	for name in s.hints.names {
		if at, seen := listed[name]; !seen || at >= kept {
			listed[name] = -1
			append(&names, name)
		}
	}
	append(&names, OTHER_NAME)
	base := make([dynamic]Member_Value, context.temp_allocator)
	for name in required {
		if picks := fitting(s, member_nodes(blocks[:], named, name), depth + 1); len(picks) > 0 {
			append(&base, Member_Value{name, picks[0]})
		}
	}
	out := make([dynamic]core.Value, context.temp_allocator)
	append(&out, object_with(base[:], ""))
	for name in names {
		picks := fitting(s, member_nodes(blocks[:], named, name), depth + 1)
		for v in picks[:min(4, len(picks))] {
			o := object_with(base[:], name, v)
			s.budget -= len(core.object_keys(o))
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
	o.slot_keys = make([dynamic]string, context.temp_allocator)
	o.slot_vals = make([dynamic]core.Value, context.temp_allocator)
	for m in base {
		if m.name != name {
			append(&o.slot_keys, m.name)
			append(&o.slot_vals, m.value)
		}
	}
	if name != "" {
		append(&o.slot_keys, name)
		append(&o.slot_vals, value)
	}
	return o
}
