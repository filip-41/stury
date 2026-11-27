// Counterexample witness search for schema comparison, confirmed directly against `check.check_document`.
// Zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/rules"

@(private = "file") MAX_CANDIDATES :: 12
@(private = "file") MAX_WITNESS_DEPTH :: 5
@(private = "file") MAX_BUILT :: 20_000
@(private = "file") MAX_LISTED :: 256
@(private = "file") ARRAY_VARIANTS :: 6
@(private = "file") MAX_HINTS :: 48
@(private = "file") PATTERN_SAMPLES :: 3
@(private = "file") MAX_PLACED :: 4
@(private = "file") MAX_OUTER :: 64
@(private = "file") MAX_PREFIX_PLACED :: 64

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
	eval:     mem.Dynamic_Arena,
	eval_a:   runtime.Allocator,
	scratch:  runtime.Allocator,
	backing:  runtime.Allocator,
	cut:      bool,
}

@(private)
refute :: proc(from, to: ^Side, foci: []Focus, scratch, backing: runtime.Allocator) -> (text: string, found, exhausted: bool) {
	s := Search {
		from    = from,
		to      = to,
		budget  = MAX_BUILT,
		scratch = scratch,
		backing = backing,
		hints   = {
			numbers = make([dynamic]f64, scratch),
			counts  = make([dynamic]int, scratch),
			names   = make([dynamic]string, scratch),
			strings = make([dynamic]string, scratch),
		},
	}
	mem.dynamic_arena_init(&s.eval, backing, backing)
	defer mem.dynamic_arena_destroy(&s.eval)
	s.eval_a = mem.dynamic_arena_allocator(&s.eval)

	append(&s.hints.numbers, 0, 1, -1, 0.5, 1.5, 2, 1e9)
	append(&s.hints.counts, 0, 1, 2)
	append(&s.hints.strings, "", "a", "ab")
	for d in ([2]^rules.Description{from.d, to.d}) {
		gather(&s.hints, d, scratch, backing)
	}
	trim_hints(&s.hints)

	judge_of(from, from.d.root)
	judge_of(to, to.d.root)
	whole := candidates(&s, {from.d.root}, 0)
	for f in foci {
		for w in found_at(&s, f) {
			for i in -1 ..< min(len(whole), MAX_OUTER) {
				outer: rules.Value = whole[i] if i >= 0 else rules.Null{}
				if text, found = confirmed(&s, {from.d.root}, {to.d.root}, placed(outer, f.path, w, scratch)); found {
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

@(private = "file")
confirmed :: proc(s: ^Search, a, b: []rules.Node_Index, v: rules.Value) -> (string, bool) {
	mem.dynamic_arena_reset(&s.eval)
	tt: write.Token_Tape
	doc, ok := value_to_tape(v, &tt, s.eval_a)
	if !ok { return "", false }
	defer write.token_tape_drop(&tt)
	taken, known := accepts_doc(s.from, a, &doc, s.eval_a)
	refused, judged := accepts_doc(s.to, b, &doc, s.eval_a)
	if taken && known && !refused && judged {
		if bytes, jok := value_to_json(v, 0, false, s.scratch, s.eval_a); jok {
			return string(bytes), true
		}
	}
	return "", false
}

@(private = "file")
found_at :: proc(s: ^Search, f: Focus) -> []rules.Value {
	out := make([dynamic]rules.Value, s.scratch)
	for v in candidates(s, f.a, min(len(f.path), MAX_WITNESS_DEPTH)) {
		if len(out) == MAX_PLACED || s.budget <= 0 { break }
		if _, found := confirmed(s, f.a, f.b, v); found { append(&out, v) }
	}
	return out[:]
}

@(private = "file")
placed :: proc(v: rules.Value, path: []tape.Step, w: rules.Value, scratch: runtime.Allocator) -> rules.Value {
	if len(path) == 0 { return w }
	#partial switch step in path[0] {
	case tape.Name:
		base := make([dynamic]rules.Member_Value, scratch)
		inner: rules.Value = rules.Null{}
		if o, is_obj := v.([]rules.Member_Value); is_obj {
			for m in o {
				if m.key == string(step) { inner = m.value }
				append(&base, m)
			}
		}
		return object_with(base[:], string(step), placed(inner, path[1:], w, scratch), scratch)
	case tape.Index:
		at := int(step)
		if at < 0 || at > MAX_PREFIX_PLACED { return v }
		items := make([dynamic]rules.Value, scratch)
		if a, is_arr := v.([]rules.Value); is_arr { append(&items, ..a) }
		for len(items) <= at { append(&items, placed(rules.Null{}, path[1:], w, scratch)) }
		items[at] = placed(items[at], path[1:], w, scratch)
		return items[:]
	}
	return v
}

@(private)
name_of_pattern :: proc(expression: string, scratch, backing: runtime.Allocator) -> string {
	drawn := make([dynamic]string, scratch)
	pattern_samples(&drawn, expression, scratch, backing)
	return drawn[0] if len(drawn) > 0 else OTHER_NAME
}

@(private = "file")
gather :: proc(h: ^Hints, d: ^rules.Description, scratch, backing: runtime.Allocator) {
	add_num :: proc(h: ^Hints, text: string) {
		if x, ok := strconv.parse_f64(text); text != "" && ok {
			append(&h.numbers, x, x + 1, x - 1, x * 2, x / 2)
		}
	}
	text_hint :: proc(h: ^Hints, v: rules.Value, scratch: runtime.Allocator) {
		if rules.value_kind(v) != .String { return }
		buf: [256]u8 = ---
		if t, owned, ok := rules.value_string(v, buf[:], scratch); ok {
			append(&h.strings, t if owned else strings.clone(t, scratch))
		}
	}
	for n in d.nodes {
		r := n.rules
		add_num(h, r.minimum)
		add_num(h, r.maximum)
		add_num(h, r.multiple_of)
		for c in ([?]u64{r.min_items, r.min_length, r.min_members, r.max_items.? or_else 0, r.max_length.? or_else 0, r.max_members.? or_else 0}) {
			cn := int(min(c, 1 << 20))
			append(&h.counts, cn, cn + 1)
		}
		if r.min_length > 0 || r.max_length != nil {
			for c in ([?]u64{r.min_length, r.min_length + 1, r.max_length.? or_else 0, (r.max_length.? or_else 0) + 1}) {
				append(&h.strings, strings.repeat("a", int(min(c, 64)), scratch))
			}
		}
		for v in n.enum_of { text_hint(h, v, scratch) }
		if c, has := n.const_of.?; has { text_hint(h, c, scratch) }
		pattern_samples(&h.strings, r.pattern, scratch, backing)
		if r.format != "" {
			if fs := format_sample(r.format, scratch); fs != "" { append(&h.strings, fs) }
		}
	}
	for o in d.objects {
		for m in o.members { append(&h.names, m.name) }
		for q in o.patterns { pattern_samples(&h.names, q.expression, scratch, backing) }
		for dep in o.dependents { append(&h.names, dep.name) }
	}
	for a in d.arrays {
		append(&h.counts, len(a.prefix), len(a.prefix) + 1)
	}
}

@(private = "file")
pattern_samples :: proc(out: ^[dynamic]string, expression: string, scratch, backing: runtime.Allocator) {
	if expression == "" { return }
	state := u64(1)
	for _ in 0 ..< PATTERN_SAMPLES {
		if text, err := regex.sample(expression, &state, 2, 1, scratch, backing); err.kind == .None {
			append(out, text)
		}
	}
}

@(private = "file")
trim_hints :: proc(h: ^Hints) {
	once :: proc(list: ^[dynamic]$T) {
		kept := 0
		for x in list^ {
			if kept == MAX_HINTS { break }
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

@(private = "file")
candidates :: proc(s: ^Search, nodes: []rules.Node_Index, depth: int) -> []rules.Value {
	out := make([dynamic]rules.Value, s.scratch)
	s.budget -= 1
	if s.budget <= 0 { return nil }
	defer s.budget -= len(out)
	bs, fits := rules.branches(s.from.d, nodes, true, MAX_BRANCHES, s.scratch, s.scratch)
	if !fits { bs, fits = rules.branches(s.from.d, nodes, false, MAX_BRANCHES, s.scratch, s.scratch) }
	if !fits { return nil }
	for ab in bs {
		an := nodes_of(s.from.d, ab[:], s.scratch)
		kinds := rules.kinds_of(s.from.d, ab[:])
		for n in an {
			if n.has_enum || n.const_of != nil {
				listed := n.enum_of[:min(len(n.enum_of), MAX_LISTED)]
				s.cut ||= len(listed) < len(n.enum_of)
				append(&out, ..listed)
				if c, has := n.const_of.?; has { append(&out, c) }
				kinds = {}
				break
			}
		}
		if .Null in kinds { append(&out, rules.Null{}) }
		if .Bool in kinds { append(&out, bool(false), bool(true)) }
		if kinds & {.Integer, .Number} != {} { for x in s.hints.numbers { append(&out, x) } }
		if .String in kinds { for t in s.hints.strings { append(&out, t) } }
		if len(an) == 0 {
			append(&out, rules.Value(([]rules.Value)(nil)), rules.Value(([]rules.Member_Value)(nil)))
		} else if depth < MAX_WITNESS_DEPTH {
			if .Array in kinds { append(&out, ..cand_arrays(s, an, depth)) }
			if .Object in kinds { append(&out, ..cand_objects(s, an, depth)) }
		}
	}
	return out[:]
}

@(private = "file")
fitting :: proc(s: ^Search, nodes: []rules.Node_Index, depth: int) -> []rules.Value {
	out := make([dynamic]rules.Value, s.scratch)
	for v in candidates(s, nodes, depth) {
		if len(out) == MAX_CANDIDATES { break }
		mem.dynamic_arena_reset(&s.eval)
		if taken, known := accepts_value(s.from, nodes, v, s.eval_a); taken && known {
			append(&out, v)
		}
	}
	return out[:]
}

@(private = "file")
cand_arrays :: proc(s: ^Search, an: []^rules.Node, depth: int) -> []rules.Value {
	blocks := make([dynamic]^rules.Array, s.scratch)
	for n in an { if n.array >= 0 { append(&blocks, &s.from.d.arrays[n.array]) } }
	out := make([dynamic]rules.Value, s.scratch)
	for count in s.hints.counts {
		if count > 6 { continue }
		per_item := make([][]rules.Value, count, s.scratch)
		for i in 0 ..< count {
			have := make([dynamic]rules.Node_Index, s.scratch)
			for blk in blocks {
				if e := blk.prefix[i] if i < len(blk.prefix) else blk.items; e != rules.NONE { append(&have, e) }
			}
			per_item[i] = fitting(s, have[:], depth + 1)
		}
		for variant in 0 ..< ARRAY_VARIANTS {
			items := make([]rules.Value, count, s.scratch)
			for picks, i in per_item {
				if len(picks) == 0 {
					items[i] = rules.Null{}
				} else {
					items[i] = picks[(i if variant == 1 else max(variant - 1, 0)) % len(picks)]
				}
			}
			s.budget -= len(items)
			append(&out, items)
		}
	}
	return out[:]
}

@(private = "file")
cand_objects :: proc(s: ^Search, an: []^rules.Node, depth: int) -> []rules.Value {
	blocks := object_blocks(s.from.d, an, s.scratch)
	names := make([dynamic]string, s.scratch)
	listed := make(map[string]int, 16, s.scratch)
	for blk in blocks {
		for m in blk.members {
			if m.name not_in listed {
				listed[m.name] = len(names)
				append(&names, m.name)
			}
		}
	}
	named := names_of_blocks(blocks[:], s.scratch)
	required := make([dynamic]string, s.scratch)
	for name in names {
		if required_in(blocks[:], named, name) { append(&required, name) }
	}
	s.cut ||= len(names) > MAX_LISTED || len(required) > MAX_LISTED
	resize(&names, min(len(names), MAX_LISTED))
	resize(&required, min(len(required), MAX_LISTED))
	kept := len(names)
	for name in s.hints.names {
		if at, seen := listed[name]; !seen || at >= kept {
			listed[name] = -1
			append(&names, name)
		}
	}
	append(&names, OTHER_NAME)
	base := make([dynamic]rules.Member_Value, s.scratch)
	for name in required {
		if picks := fitting(s, member_nodes(blocks[:], named, name, s.scratch), depth + 1); len(picks) > 0 {
			append(&base, rules.Member_Value{key = name, value = picks[0]})
		}
	}
	out := make([dynamic]rules.Value, s.scratch)
	append(&out, object_with(base[:], "", rules.Null{}, s.scratch))
	for name in names {
		picks := fitting(s, member_nodes(blocks[:], named, name, s.scratch), depth + 1)
		for v in picks[:min(4, len(picks))] {
			o := object_with(base[:], name, v, s.scratch)
			s.budget -= len(o)
			append(&out, o)
		}
	}
	return out[:]
}

@(private = "file")
object_with :: proc(base: []rules.Member_Value, name: string, value: rules.Value, scratch: runtime.Allocator) -> []rules.Member_Value {
	out := make([dynamic]rules.Member_Value, 0, len(base) + 1, scratch)
	for m in base {
		if m.key != name { append(&out, m) }
	}
	if name != "" { append(&out, rules.Member_Value{key = name, value = value}) }
	return out[:]
}
