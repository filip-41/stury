// Seeded deterministic JSON sample generator for `rules.Description` verified against `check.check_document`.
// Supports `prefixItems`/`items`, `allOf`/`anyOf`/`oneOf`, `if`/`then`/`else`, `$ref`/`$dynamicRef`,
// `const`/`enum`, bounded numbers + `multipleOf`, `pattern` (via `regex.sample`), all 19 string formats,
// `uniqueItems`, `contains`, `dependentRequired`, `patternProperties`, `propertyNames`, `unevaluatedProperties`,
// and single-rule invalid sample generation (`opts.invalid`).
// Zero `core:mem/virtual`, zero `context.temp_allocator`, explicit depth bound, WASM-clean.
package schema

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/base/kernel"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

// Options controlling `sample` / `sample_each`. Zero value draws 1 valid JSON value from seed 0.
Sample_Options :: struct {
	seed:          u64,
	// Number of values to draw (1 when 0).
	count:         int,
	// Maximum depth of optional nesting (4 when 0; hard-capped at 32).
	depth:         int,
	// Maximum draw attempts per sample before returning `.No_Sample` (64 when 0).
	tries:         int,
	// Maximum value/character budget per draw (65536 when 0).
	size:          int,
	// Generate invalid samples that fail exactly one rule each.
	invalid:       bool,
	// Assert `format` keywords even if the schema did not enable format assertion.
	format_assert: bool,
	// Indentation for JSON output.
	indent:        u8,
	tab:           bool,
}

// Callback receiving each generated JSON text. `text` is valid until the callback returns.
Sample_Sink :: #type proc(text: []u8, user: rawptr)

@(private = "file")
Part :: struct {
	node:  rules.Node_Index,
	extra: ^rules.Rules,
}

@(private = "file")
Gen :: struct {
	d:       ^rules.Description,
	state:   u64,
	extra:   int,
	room:    int,
	culprit: rules.Node_Index,
	scratch: runtime.Allocator,
	eval:    ^mem.Dynamic_Arena,
	eval_a:  runtime.Allocator,
	backing: runtime.Allocator,
}

// Splitmix64 PRNG matching `lib/base/regex/sample.odin`.
@(private = "file")
rng_next :: proc "contextless" (state: ^u64) -> u64 {
	state^ += 0x9e3779b97f4a7c15
	z := state^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

@(private = "file")
rng_below :: proc "contextless" (state: ^u64, n: int) -> int {
	return int(rng_next(state) % u64(max(n, 1)))
}

// Draws `max(opts.count, 1)` JSON values satisfying `d` (or failing one rule when `opts.invalid`),
// verified against `check.check_document`, and delivers each to `sink`.
@(require_results)
sample_each :: proc(d: ^rules.Description, opts: Sample_Options, sink: Sample_Sink, user: rawptr, allocator := context.allocator) -> Error {
	if d == nil || d.root < 0 || int(d.root) >= len(d.nodes) {
		return make_error(.Bad_Option, "description", "empty description", allocator = allocator)
	}
	asserted := asserting(d, opts.format_assert, allocator)
	defer asserting_destroy(&asserted, opts.format_assert, allocator)
	plan, cerr := check.compile(&asserted, allocator)
	if cerr.kind != .None {
		return Error{kind = .Compile, keyword = cerr.keyword, compile_err = cerr}
	}
	defer check.plan_destroy(&plan)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&arena)
	scratch := mem.dynamic_arena_allocator(&arena)

	eval_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&eval_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&eval_arena)
	eval_a := mem.dynamic_arena_allocator(&eval_arena)

	g := Gen {
		d       = &asserted,
		state   = opts.seed,
		scratch = scratch,
		eval    = &eval_arena,
		eval_a  = eval_a,
		backing = allocator,
	}

	for _ in 0 ..< max(opts.count, 1) {
		mem.dynamic_arena_reset(&arena)
		mem.dynamic_arena_reset(&eval_arena)
		text, ok := draw_verified_text(&g, &plan, opts)
		if !ok {
			return no_sample_error(&g, .No_Invalid_Sample if opts.invalid else .No_Sample, allocator)
		}
		sink(text, user)
	}
	return {}
}

// Draws `max(opts.count, 1)` JSON values into a slice owned by `allocator`.
@(require_results)
sample :: proc(d: ^rules.Description, opts := Sample_Options{}, allocator := context.allocator) -> (out: [][]u8, err: Error) {
	Collect :: struct {
		list: [dynamic][]u8,
		oom:  bool,
	}
	ctx := Collect{list = make([dynamic][]u8, allocator)}
	err = sample_each(d, opts, proc(text: []u8, user: rawptr) {
		c := (^Collect)(user)
		if c.oom {
			return
		}
		cp, cerr := slice.clone(text, c.list.allocator)
		if cerr != nil {
			c.oom = true
			return
		}
		if _, aerr := append(&c.list, cp); aerr != nil {
			delete(cp, c.list.allocator)
			c.oom = true
		}
	}, &ctx, allocator)
	if err.kind != .None || ctx.oom {
		for t in ctx.list {
			delete(t, allocator)
		}
		delete(ctx.list)
		if err.kind == .None {
			return nil, make_error(.No_Memory, "sample", "out of memory", allocator = allocator)
		}
		return nil, err
	}
	return ctx.list[:], {}
}

// Deterministic format sample used by both `sample` and `compare_witness`.
@(private)
format_sample :: proc(name: string, allocator: runtime.Allocator) -> string {
	g := Gen{state = 0, scratch = allocator, backing = allocator}
	return format_text(&g, name)
}

@(private = "file")
no_sample_error :: proc(g: ^Gen, kind: Error_Kind, allocator: runtime.Allocator) -> Error {
	at := g.culprit if g.culprit != rules.NONE else g.d.root
	steps := make([dynamic]tape.Step, g.scratch)
	seen := make([]bool, len(g.d.nodes), g.scratch)
	ps := Path_Search{d = g.d, target = at, steps = &steps, seen = seen}
	if reaches_node(&ps, g.d.root, 0) {
		return make_error(kind, "sample", "no sample found", 0, steps[:], allocator)
	}
	return make_error(kind, "sample", "no sample found", 0, nil, allocator)
}

@(private = "file")
Path_Search :: struct {
	d:      ^rules.Description,
	target: rules.Node_Index,
	steps:  ^[dynamic]tape.Step,
	seen:   []bool,
}

@(private = "file", rodata)
ARM_WORDS := [3]string{"allOf", "anyOf", "oneOf"}

@(private = "file", rodata)
SINGLE_WORDS := [6]string{"not", "if", "then", "else", "unevaluatedItems", "unevaluatedProperties"}

@(private = "file")
reaches_node :: proc(s: ^Path_Search, at: rules.Node_Index, depth: int) -> bool {
	if at == s.target {
		return true
	}
	if at == rules.NONE || s.seen[at] || depth > 64 {
		return false
	}
	s.seen[at] = true
	n := &s.d.nodes[at]
	if r, ok := n.ref.?; ok && through_node(s, r, depth + 1, tape.Name(rules.ref_keyword(n))) {
		return true
	}
	if r, ok := n.dynamic_ref.?; ok && through_node(s, r, depth + 1, tape.Name(rules.dynamic_keyword(n))) {
		return true
	}
	for arms, word in ([3][]rules.Node_Index{n.all_of, n.any_of, n.one_of}) {
		for x, i in arms {
			if through_node(s, x, depth + 1, tape.Name(ARM_WORDS[word]), tape.Index(i)) {
				return true
			}
		}
	}
	for x, word in ([?]Maybe(rules.Node_Index){n.not, n.cond.test, n.cond.then, n.cond.other, n.unevaluated_items, n.unevaluated_properties}) {
		if id, ok := x.?; ok && through_node(s, id, depth + 1, tape.Name(SINGLE_WORDS[word])) {
			return true
		}
	}
	if n.array >= 0 {
		a := &s.d.arrays[n.array]
		for x, i in a.prefix {
			if through_node(s, x, depth + 1, tape.Name("items" if a.tuple else "prefixItems"), tape.Index(i)) {
				return true
			}
		}
		if through_node(s, a.items, depth + 1, tape.Name("additionalItems" if a.tuple else "items")) {
			return true
		}
		if c, ok := a.contains.?; ok && through_node(s, c, depth + 1, tape.Name("contains")) {
			return true
		}
	}
	if n.object >= 0 {
		o := &s.d.objects[n.object]
		for m in o.members {
			if through_node(s, m.node, depth + 1, tape.Name("properties"), tape.Name(m.name)) {
				return true
			}
		}
		for p in o.patterns {
			if through_node(s, p.node, depth + 1, tape.Name("patternProperties"), tape.Name(p.expression)) {
				return true
			}
		}
		dep_kw := "dependencies" if o.dependencies else "dependentSchemas"
		for dep in o.dependents {
			if dn, ok := dep.node.?; ok && through_node(s, dn, depth + 1, tape.Name(dep_kw), tape.Name(dep.name)) {
				return true
			}
		}
		if through_node(s, o.additional, depth + 1, tape.Name("additionalProperties")) ||
		   through_node(s, o.keys, depth + 1, tape.Name("propertyNames")) {
			return true
		}
	}
	return false
}

@(private = "file")
through_node :: proc(s: ^Path_Search, node: rules.Node_Index, depth: int, steps: ..tape.Step) -> bool {
	if node == rules.NONE {
		return false
	}
	before := len(s.steps)
	append(s.steps, ..steps)
	if reaches_node(s, node, depth) {
		return true
	}
	resize(s.steps, before)
	return false
}

@(private = "file")
check_val :: proc(g: ^Gen, plan: ^check.Plan, v: rules.Value) -> bool {
	if g.eval != nil {
		mem.dynamic_arena_reset(g.eval)
	}
	a := g.eval_a if g.eval != nil else g.backing
	tt: write.Token_Tape
	doc, ok := value_to_tape(v, &tt, a)
	if !ok {
		return false
	}
	defer write.token_tape_drop(&tt)
	res := check.check_document(&doc, plan, {}, nil, a)
	valid := res.valid
	check.result_destroy(&res)
	return valid
}

@(private = "file")
fails_alone :: proc(g: ^Gen, plan: ^check.Plan, v: rules.Value) -> bool {
	if g.eval != nil {
		mem.dynamic_arena_reset(g.eval)
	}
	a := g.eval_a if g.eval != nil else g.backing
	tt: write.Token_Tape
	doc, ok := value_to_tape(v, &tt, a)
	if !ok {
		return false
	}
	defer write.token_tape_drop(&tt)
	sink: check.Sink
	check.sink_init(&sink, a)
	defer check.sink_destroy(&sink)
	res := check.check_document(&doc, plan, {}, &sink, a)
	valid := res.valid
	check.result_destroy(&res)
	return !valid && len(sink.entries) == 1
}

@(private = "file")
draw_verified_text :: proc(g: ^Gen, plan: ^check.Plan, opts: Sample_Options) -> (text: []u8, ok: bool) {
	depth := min(opts.depth if opts.depth > 0 else 4, 32)
	tries := opts.tries if opts.tries > 0 else 64
	for attempt in 0 ..< tries {
		g.extra = attempt / 4
		g.room = opts.size if opts.size > 0 else 1 << 16
		g.culprit = rules.NONE
		v, drawn := draw_value(g, {{node = g.d.root}}, depth)
		if !drawn {
			continue
		}
		if opts.invalid {
			if broken_v, brok := break_value(g, plan, v); brok {
				if bytes, wok := value_to_json(broken_v, opts.indent, opts.tab, g.scratch, g.scratch); wok {
					return bytes, true
				}
			}
		} else if check_val(g, plan, v) {
			if bytes, wok := value_to_json(v, opts.indent, opts.tab, g.scratch, g.scratch); wok {
				return bytes, true
			}
		}
	}
	if opts.invalid {
		v: rules.Value = rules.Null{}
		if broken_v, brok := break_value(g, plan, v); brok {
			if bytes, wok := value_to_json(broken_v, opts.indent, opts.tab, g.scratch, g.scratch); wok {
				return bytes, true
			}
		}
	}
	return nil, false
}

@(private = "file")
spend :: proc(g: ^Gen, n: int) -> bool {
	g.room -= n
	return g.room >= 0
}

@(private = "file")
below :: proc "contextless" (g: ^Gen, n: int) -> int {
	return rng_below(&g.state, n)
}

@(private = "file")
takes :: proc "contextless" (k: rules.Kinds, of: rules.Kind) -> bool {
	return of in k || (of == .Integer && .Number in k)
}

@(private = "file")
flatten_parts :: proc(g: ^Gen, out: ^[dynamic]Part, p: Part, hops: int) -> bool {
	if p.node == rules.NONE {
		return true
	}
	if hops > 32 {
		return false
	}
	append(out, p)
	n := &g.d.nodes[p.node]
	if r, ok := n.ref.?; ok && !flatten_parts(g, out, {node = r}, hops + 1) {
		return false
	}
	if r, ok := n.dynamic_ref.?; ok && !flatten_parts(g, out, {node = r}, hops + 1) {
		return false
	}
	for a in n.all_of {
		if !flatten_parts(g, out, {node = a}, hops + 1) {
			return false
		}
	}
	for arms in ([2][]rules.Node_Index{n.any_of, n.one_of}) {
		if len(arms) > 0 && !flatten_parts(g, out, {node = arms[below(g, len(arms))]}, hops + 1) {
			return false
		}
	}
	if test, ok := n.cond.test.?; ok {
		then, has_then := n.cond.then.?
		other, has_other := n.cond.other.?
		if below(g, 2) == 0 {
			if !flatten_parts(g, out, {node = test}, hops + 1) || (has_then && !flatten_parts(g, out, {node = then}, hops + 1)) {
				return false
			}
		} else if has_other && !flatten_parts(g, out, {node = other}, hops + 1) {
			return false
		}
	}
	return true
}

@(private = "file")
draw_value :: proc(g: ^Gen, given: []Part, depth: int) -> (v: rules.Value, ok: bool) {
	defer if !ok && g.culprit == rules.NONE {
		for p in given {
			if p.node != rules.NONE {
				g.culprit = p.node
			}
		}
	}
	if depth < -6 || !spend(g, 1) {
		return
	}
	all := make([dynamic]Part, g.scratch)
	for p in given {
		if p.extra != nil {
			append(&all, p)
		}
		if !flatten_parts(g, &all, p, 0) {
			return
		}
	}
	for p in all {
		if p.node == rules.NONE {
			continue
		}
		n := &g.d.nodes[p.node]
		if c, has := n.const_of.?; has {
			return c, true
		}
		if n.has_enum {
			if len(n.enum_of) == 0 {
				return
			}
			return n.enum_of[below(g, len(n.enum_of))], true
		}
	}
	candidates: [rules.Kind]bool
	count := 0
	for k in rules.Kind {
		candidates[k] = depth > 0 || (k != .Array && k != .Object)
		for p in all {
			candidates[k] &&= p.node == rules.NONE || takes(g.d.nodes[p.node].kinds, k)
		}
		count += int(candidates[k])
	}
	if count == 0 {
		return
	}
	at := below(g, count)
	kind: rules.Kind
	for k in rules.Kind {
		if candidates[k] {
			if at == 0 {
				kind = k
				break
			}
			at -= 1
		}
	}
	list := make([dynamic]^rules.Rules, g.scratch)
	for &p in all {
		if p.node != rules.NONE {
			append(&list, &g.d.nodes[p.node].rules)
		}
		if p.extra != nil {
			append(&list, p.extra)
		}
	}
	switch kind {
	case .Null:
		return rules.Null{}, true
	case .Bool:
		return below(g, 2) == 0, true
	case .Integer, .Number:
		return draw_number(g, list[:], kind == .Integer)
	case .String:
		return draw_string(g, list[:])
	case .Array:
		return draw_array(g, list[:], all[:], depth)
	case .Object:
		return draw_object(g, all[:], list[:], depth)
	}
	return
}

@(private = "file")
gcd_u128 :: proc "contextless" (a, b: u128) -> u128 {
	x, y := a, b
	for y != 0 {
		x, y = y, x % y
	}
	return x
}

@(private = "file")
parse_step_decimal :: proc(text: string, scratch: runtime.Allocator) -> (mantissa: u128, exp: int, ok: bool) {
	d := rules.decimal_of(text)
	if d.head == "" || d.neg || d.wide != "" {
		return 0, 0, false
	}
	digits := strings.concatenate({d.head, d.tail}, scratch)
	if len(digits) == 0 || len(digits) > 36 {
		return 0, 0, false
	}
	m := u128(0)
	for c in transmute([]u8)digits {
		if c < '0' || c > '9' {
			return 0, 0, false
		}
		m = m * 10 + u128(c - '0')
	}
	if m == 0 {
		return 0, 0, false
	}
	e := int(clamp(d.point - i128(len(digits)), -100_000, 100_000))
	for m % 10 == 0 {
		m /= 10
		e += 1
	}
	return m, e, true
}

@(private = "file")
combine_steps :: proc "contextless" (m1: u128, e1: int, m2: u128, e2: int) -> (m: u128, e: int, ok: bool) {
	e = min(e1, e2)
	a, b := m1, m2
	diff1, diff2 := e1 - e, e2 - e
	if diff1 > 36 || diff2 > 36 {
		return 0, 0, false
	}
	for _ in 0 ..< diff1 {
		if a > max(u128) / 10 {
			return 0, 0, false
		}
		a *= 10
	}
	for _ in 0 ..< diff2 {
		if b > max(u128) / 10 {
			return 0, 0, false
		}
		b *= 10
	}
	g := gcd_u128(a, b)
	q := a / g
	if b > max(u128) / q {
		return 0, 0, false
	}
	m = q * b
	for m % 10 == 0 {
		m /= 10
		e += 1
	}
	return m, e, true
}

@(private = "file")
draw_number :: proc(g: ^Gen, list: []^rules.Rules, whole: bool) -> (v: rules.Value, ok: bool) {
	lo_txt, hi_txt := "", ""
	low_open, high_open := false, false
	has_step := false
	step_m: u128 = 1
	step_e: int = 0
	for r in list {
		if r.minimum != "" {
			if !rules.valid_decimal_text(r.minimum) {
				return
			}
			if lo_txt == "" {
				lo_txt, low_open = r.minimum, r.exclusive_minimum
			} else if cmp := rules.decimal_compare(rules.decimal_of(r.minimum), rules.decimal_of(lo_txt)); cmp > 0 || (cmp == 0 && r.exclusive_minimum) {
				lo_txt, low_open = r.minimum, r.exclusive_minimum
			}
		}
		if r.maximum != "" {
			if !rules.valid_decimal_text(r.maximum) {
				return
			}
			if hi_txt == "" {
				hi_txt, high_open = r.maximum, r.exclusive_maximum
			} else if cmp := rules.decimal_compare(rules.decimal_of(r.maximum), rules.decimal_of(hi_txt)); cmp < 0 || (cmp == 0 && r.exclusive_maximum) {
				hi_txt, high_open = r.maximum, r.exclusive_maximum
			}
		}
		if r.multiple_of != "" && !finer_than_doubles(r.multiple_of) {
			sm, se, sok := parse_step_decimal(r.multiple_of, g.scratch)
			if !sok {
				return
			}
			if !has_step {
				step_m, step_e, has_step = sm, se, true
			} else {
				cm, ce, cok := combine_steps(step_m, step_e, sm, se)
				if !cok {
					return
				}
				step_m, step_e = cm, ce
			}
		}
	}
	if lo_txt != "" && hi_txt != "" {
		cmp := rules.decimal_compare(rules.decimal_of(lo_txt), rules.decimal_of(hi_txt))
		if cmp > 0 || (cmp == 0 && (low_open || high_open)) {
			return
		}
	}
	lo, hi := math.inf_f64(-1), math.inf_f64(1)
	if lo_txt != "" {
		parsed_lo, pok := strconv.parse_f64(lo_txt)
		if !pok || math.is_nan(parsed_lo) || math.is_inf(parsed_lo, 0) {
			return
		}
		lo = parsed_lo
	}
	if hi_txt != "" {
		parsed_hi, pok := strconv.parse_f64(hi_txt)
		if !pok || math.is_nan(parsed_hi) || math.is_inf(parsed_hi, 0) {
			return
		}
		hi = parsed_hi
	}
	if math.is_inf(lo, 0) && math.is_inf(hi, 0) {
		lo, hi = -100, 1000
	} else if math.is_inf(lo, 0) {
		lo = hi - 1000
	} else if math.is_inf(hi, 0) {
		hi = lo + 1000
	}
	if lo > hi {
		return
	}
	if whole {
		if !has_step {
			step_m, step_e, has_step = 1, 0, true
		} else {
			cm, ce, cok := combine_steps(step_m, step_e, 1, 0)
			if !cok {
				return
			}
			step_m, step_e = cm, ce
		}
	}
	if has_step {
		return draw_stepped(g, step_m, step_e, lo, hi, lo_txt, hi_txt, low_open, high_open)
	}
	x := lo + (hi - lo) * (0.1 + 0.8 * f64(below(g, 1000)) / 1000)
	val := math.round(x * 100) / 100 if hi - lo >= 1 else x
	if math.is_nan(val) || math.is_inf(val, 0) {
		return
	}
	buf: [64]u8 = ---
	s := strconv.write_float(buf[:], val, 'g', -1, 64, {})
	if !decimal_in_bounds(s, lo_txt, hi_txt, low_open, high_open) {
		// Fall back to midpoint for tight open intervals.
		mid := lo + (hi - lo) * 0.5
		s = strconv.write_float(buf[:], mid, 'g', -1, 64, {})
		if !decimal_in_bounds(s, lo_txt, hi_txt, low_open, high_open) {
			return
		}
	}
	return rules.Number_Text{text = strings.clone(s, g.scratch)}, true
}

@(private = "file")
decimal_in_bounds :: proc "contextless" (text, lo_txt, hi_txt: string, low_open, high_open: bool) -> bool {
	if !rules.valid_decimal_text(text) {
		return false
	}
	d := rules.decimal_of(text)
	if lo_txt != "" {
		c := rules.decimal_compare(d, rules.decimal_of(lo_txt))
		if c < 0 || (c == 0 && low_open) {
			return false
		}
	}
	if hi_txt != "" {
		c := rules.decimal_compare(d, rules.decimal_of(hi_txt))
		if c > 0 || (c == 0 && high_open) {
			return false
		}
	}
	return true
}

@(private = "file")
finer_than_doubles :: proc "contextless" (step: string) -> bool {
	d := rules.decimal_of(step)
	return d.head == "1" && d.tail == "" && (d.wide_neg if d.wide != "" else d.point <= -339)
}

@(private = "file")
draw_stepped :: proc(g: ^Gen, mantissa: u128, exp: int, lo, hi: f64, lo_txt, hi_txt: string, low_open, high_open: bool) -> (v: rules.Value, ok: bool) {
	if mantissa == 0 || mantissa > u128(max(i128)) / 2 {
		return
	}
	unit := f64(mantissa) * math.pow(10, f64(exp))
	if unit <= 0 || math.is_nan(unit) || math.is_inf(unit, 0) {
		return
	}
	first := math.ceil(lo / unit)
	last := math.floor(hi / unit)
	if math.is_nan(first) || math.is_inf(first, 0) || math.is_nan(last) || math.is_inf(last, 0) {
		return
	}
	// Clamp indices to avoid `i128` cast UB on extreme floating-point magnitudes.
	LIMIT :: 1e18
	if first < -LIMIT {
		first = -LIMIT
	}
	if last > LIMIT {
		last = LIMIT
	}
	if first > last {
		return
	}
	k_first := i128(first)
	k_last := i128(last)
	max_k := i128(max(i128)) / i128(mantissa)
	if k_first < -max_k {
		k_first = -max_k
	}
	if k_last > max_k {
		k_last = max_k
	}
	if k_first > k_last {
		return
	}
	format_k :: proc(k: i128, mantissa: u128, exp: int, scratch: runtime.Allocator) -> string {
		prod := k * i128(mantissa)
		raw_str := fmt.aprintf("%de%d", prod, exp, allocator = scratch)
		b := strings.builder_make(scratch)
		rules.write_decimal(&b, rules.decimal_of(raw_str))
		return strings.to_string(b)
	}
	// Adjust endpoints using exact decimal comparison (never float equality!).
	if lo_txt != "" {
		lo_dec := rules.decimal_of(lo_txt)
		for _ in 0 ..< 4 {
			if k_first > k_last {
				return
			}
			c := rules.decimal_compare(rules.decimal_of(format_k(k_first, mantissa, exp, g.scratch)), lo_dec)
			if c > 0 || (c == 0 && !low_open) {
				break
			}
			k_first += 1
		}
	}
	if hi_txt != "" {
		hi_dec := rules.decimal_of(hi_txt)
		for _ in 0 ..< 4 {
			if k_first > k_last {
				return
			}
			c := rules.decimal_compare(rules.decimal_of(format_k(k_last, mantissa, exp, g.scratch)), hi_dec)
			if c < 0 || (c == 0 && !high_open) {
				break
			}
			k_last -= 1
		}
	}
	if k_first > k_last {
		return
	}
	span := k_last - k_first
	pick := i128(below(g, int(min(span, 1_000_000)) + 1))
	cand := format_k(k_first + pick, mantissa, exp, g.scratch)
	if !decimal_in_bounds(cand, lo_txt, hi_txt, low_open, high_open) {
		return
	}
	return rules.Number_Text{text = cand}, true
}

@(private = "file")
draw_string :: proc(g: ^Gen, list: []^rules.Rules) -> (v: rules.Value, ok: bool) {
	lo, hi, pattern, format := u64(0), max(u64), "", ""
	for r in list {
		lo = max(lo, r.min_length)
		hi = min(hi, r.max_length.? or_else max(u64))
		pattern = pattern if pattern != "" else r.pattern
		format = format if format != "" else r.format
	}
	if lo > hi || lo > u64(max(g.room, 0)) {
		return
	}
	for tries in 0 ..< 8 {
		s := ""
		switch {
		case pattern != "":
			least := int(lo) + below(g, 1 + int(min(hi - lo, u64(4 + g.extra))))
			sampled, rerr := regex.sample(pattern, &g.state, g.extra + tries, least, g.scratch, g.backing)
			if rerr.kind != .None {
				return
			}
			s = sampled
		case format != "":
			fs := format_text(g, format)
			if fs != "" {
				s = fs
			} else {
				s = rand_letters(g, max(int(lo), 1 if hi > 0 else 0) + below(g, 1 + int(min(hi - lo, u64(4 + g.extra)))))
			}
		case:
			s = rand_letters(g, max(int(lo), 1 if hi > 0 else 0) + below(g, 1 + int(min(hi - lo, u64(4 + g.extra)))))
		}
		if n := u64(kernel.count_chars(transmute([]u8)s)); n >= lo && n <= hi && spend(g, int(n)) {
			return s, true
		}
		if pattern == "" {
			return
		}
	}
	return
}

@(private = "file")
rand_letters :: proc(g: ^Gen, n: int) -> string {
	b := make([]u8, n, g.scratch)
	for &c in b {
		c = u8('a' + below(g, 26))
	}
	return string(b)
}

@(private = "file")
format_text :: proc(g: ^Gen, name: string) -> string {
	switch name {
	case "date-time":
		return fmt.aprintf("20%02d-%02d-%02dT%02d:%02d:%02dZ", below(g, 100), 1 + below(g, 12), 1 + below(g, 28), below(g, 24), below(g, 60), below(g, 60), allocator = g.scratch)
	case "date":
		return fmt.aprintf("20%02d-%02d-%02d", below(g, 100), 1 + below(g, 12), 1 + below(g, 28), allocator = g.scratch)
	case "time":
		return fmt.aprintf("%02d:%02d:%02dZ", below(g, 24), below(g, 60), below(g, 60), allocator = g.scratch)
	case "email", "idn-email":
		return fmt.aprintf("%s@%s.com", rand_letters(g, 5), rand_letters(g, 5), allocator = g.scratch)
	case "hostname", "idn-hostname":
		return fmt.aprintf("%s.example.com", rand_letters(g, 5), allocator = g.scratch)
	case "ipv4":
		return fmt.aprintf("%d.%d.%d.%d", below(g, 256), below(g, 256), below(g, 256), below(g, 256), allocator = g.scratch)
	case "ipv6":
		return fmt.aprintf("2001:db8::%x:%x", below(g, 65536), below(g, 65536), allocator = g.scratch)
	case "uri", "iri":
		return fmt.aprintf("https://%s.example.com/%s", rand_letters(g, 5), rand_letters(g, 4), allocator = g.scratch)
	case "uuid":
		return fmt.aprintf(
			"%08x-%04x-4%03x-8%03x-%012x",
			rng_next(&g.state) & 0xffffffff,
			rng_next(&g.state) & 0xffff,
			rng_next(&g.state) & 0xfff,
			rng_next(&g.state) & 0xfff,
			rng_next(&g.state) & 0xffffffffffff,
			allocator = g.scratch,
		)
	case "json-pointer":
		return fmt.aprintf("/%s/%d", rand_letters(g, 4), below(g, 10), allocator = g.scratch)
	case "relative-json-pointer":
		return fmt.aprintf("%d/%s", below(g, 10), rand_letters(g, 4), allocator = g.scratch)
	case "duration":
		return fmt.aprintf("P%dDT%dH", below(g, 30), below(g, 24), allocator = g.scratch)
	case "uri-reference", "iri-reference":
		return fmt.aprintf("/%s/%s", rand_letters(g, 4), rand_letters(g, 4), allocator = g.scratch)
	case "uri-template":
		return strings.concatenate({"https://example.com/", rand_letters(g, 4), "/{", rand_letters(g, 3), "}"}, g.scratch)
	case "regex":
		return fmt.aprintf("^%s[0-9]+$", rand_letters(g, 3), allocator = g.scratch)
	}
	return ""
}

@(private = "file")
draw_array :: proc(g: ^Gen, list: []^rules.Rules, parts: []Part, depth: int) -> (v: rules.Value, ok: bool) {
	lo, hi, unique := u64(0), max(u64), false
	for r in list {
		lo, hi, unique = max(lo, r.min_items), min(hi, r.max_items.? or_else max(u64)), unique || r.unique
	}
	blocks := make([dynamic]^rules.Array, g.scratch)
	rem_need := make([dynamic]u64, g.scratch)
	max_need := u64(0)
	max_prefix := 0
	for p in parts {
		if p.node == rules.NONE || g.d.nodes[p.node].array < 0 {
			continue
		}
		a := &g.d.arrays[g.d.nodes[p.node].array]
		append(&blocks, a)
		max_prefix = max(max_prefix, len(a.prefix))
		bneed := u64(0)
		if _, has := a.contains.?; has {
			bneed = a.min_contains.? or_else 1
			bmost := a.max_contains.? or_else max(u64)
			if bneed > bmost {
				return
			}
			// If `minContains == 0 && maxContains == 0`, skip injecting `contains`.
			if bneed == 0 {
				bneed = 0
			}
			max_need = max(max_need, bneed)
		}
		append(&rem_need, bneed)
	}
	lo = max(lo, max_need)
	if lo > hi || lo > u64(max(g.room, 0)) {
		return
	}
	target := min(hi, lo + u64(below(g, 3 + g.extra))) if depth > 0 else lo
	items := make([dynamic]rules.Value, g.scratch)
	for i := 0; ; i += 1 {
		still_need := false
		for rn in rem_need {
			if rn > 0 {
				still_need = true
				break
			}
		}
		if u64(i) >= target && !still_need {
			break
		}
		if u64(i) >= hi || u64(i) >= u64(max(g.room, 0)) {
			break
		}
		base_at := make([dynamic]Part, g.scratch)
		for a in blocks {
			if i < len(a.prefix) {
				append(&base_at, Part{node = a.prefix[i]})
			} else if a.items != rules.NONE {
				append(&base_at, Part{node = a.items})
			}
		}
		// Schedule needed `contains` blocks: prefer positions after `prefixItems`, or when forced by `hi`,
		// falling back to base positional constraints if a prefix position is incompatible with `contains`.
		with_contains := make([dynamic]Part, g.scratch)
		append(&with_contains, ..base_at[:])
		used_contains := make([]bool, len(blocks), g.scratch)
		tried_contains := false
		for a, bi in blocks {
			if rem_need[bi] == 0 {
				continue
			}
			if c, has := a.contains.?; has {
				if i >= max_prefix || u64(i) + rem_need[bi] >= hi {
					append(&with_contains, Part{node = c})
					used_contains[bi] = true
					tried_contains = true
				}
			}
		}
		e: rules.Value
		got: bool
		matched_contains := false
		if tried_contains {
			for _ in 0 ..< (6 if unique else 1) {
				if e, got = draw_value(g, with_contains[:], depth - 1); got && !(unique && val_repeated(g, items[:], e)) {
					matched_contains = true
					break
				}
			}
		}
		if !got {
			for _ in 0 ..< (6 if unique else 1) {
				if e, got = draw_value(g, base_at[:], depth - 1); got && !(unique && val_repeated(g, items[:], e)) {
					break
				}
			}
		}
		if !got {
			if u64(i) < lo || still_need {
				return
			}
			break
		}
		if matched_contains {
			for bi in 0 ..< len(rem_need) {
				if used_contains[bi] && rem_need[bi] > 0 {
					rem_need[bi] -= 1
				}
			}
		}
		append(&items, e)
	}
	for rn in rem_need {
		if rn > 0 {
			return
		}
	}
	if u64(len(items)) < lo {
		return
	}
	return items[:], true
}

@(private = "file")
val_repeated :: proc(g: ^Gen, items: []rules.Value, e: rules.Value) -> bool {
	if g.eval != nil {
		mem.dynamic_arena_reset(g.eval)
	}
	a := g.eval_a if g.eval != nil else g.backing
	for x in items {
		eq, err := rules.value_equal(x, e, .Last, a)
		if err == nil && eq {
			return true
		}
	}
	return false
}

@(private = "file")
Obj_Entry :: struct {
	name:     string,
	parts:    [dynamic]Part,
	required: bool,
}

@(private = "file")
draw_object :: proc(g: ^Gen, parts: []Part, list: []^rules.Rules, depth: int) -> (v: rules.Value, ok: bool) {
	blocks := make([dynamic]^rules.Object, g.scratch)
	entries := make([dynamic]Obj_Entry, g.scratch)
	for p in parts {
		if p.node != rules.NONE && g.d.nodes[p.node].object >= 0 {
			append(&blocks, &g.d.objects[g.d.nodes[p.node].object])
		}
	}
	for b in blocks {
		for &m in b.members {
			e := obj_entry(g, &entries, m.name)
			e.required ||= m.required
			if !m.only_required {
				append(&e.parts, Part{node = m.node, extra = &m.rules})
			}
		}
	}
	for &e in entries {
		for b in blocks {
			if !block_listed(b, e.name) && b.additional != rules.NONE {
				append(&e.parts, Part{node = b.additional})
			}
		}
	}
	seen_deps := make(map[rules.Node_Index]bool, 4, g.scratch)
	for _ in 0 ..< 4 {
		for b_i := 0; b_i < len(blocks); b_i += 1 {
			b := blocks[b_i]
			for dep in b.dependents {
				if !entry_present(entries[:], dep.name, depth) {
					continue
				}
				for name in dep.required {
					obj_entry(g, &entries, name, b).required = true
				}
				if dn, has_dn := dep.node.?; has_dn && !seen_deps[dn] {
					seen_deps[dn] = true
					dep_parts := make([dynamic]Part, g.scratch)
					if flatten_parts(g, &dep_parts, {node = dn}, 0) {
						for dp in dep_parts {
							if dp.node == rules.NONE {
								continue
							}
							if !takes(g.d.nodes[dp.node].kinds, .Object) {
								g.culprit = dp.node
								return
							}
							if g.d.nodes[dp.node].object >= 0 {
								db := &g.d.objects[g.d.nodes[dp.node].object]
								append(&blocks, db)
								for &m in db.members {
									e := obj_entry(g, &entries, m.name)
									e.required ||= m.required
									if !m.only_required {
										append(&e.parts, Part{node = m.node, extra = &m.rules})
									}
								}
							}
						}
					}
				}
			}
		}
	}
	least, most := 0, max(int)
	for r in list {
		least = max(least, int(r.min_members))
		most = min(most, int(r.max_members.? or_else u64(max(int))))
	}
	wanted := make([dynamic]Obj_Entry, g.scratch)
	for &e, idx in entries {
		if e.required || (depth > 0 && below(g, 2) == 0) || len(wanted) + (len(entries) - idx - 1) < least {
			append(&wanted, e)
		}
	}
	more := 0
	for b in blocks {
		for p in b.patterns {
			if (len(wanted) < least || below(g, 2) == 0) && depth > 0 {
				if name, rerr := regex.sample(p.expression, &g.state, g.extra, 0, g.scratch, g.backing); rerr.kind == .None && !entry_named(wanted[:], name) {
					e := Obj_Entry{name = name, parts = make([dynamic]Part, g.scratch)}
					append(&e.parts, Part{node = p.node})
					append(&wanted, e)
				}
			}
		}
		if len(b.members) == 0 && b.additional != rules.NONE && len(wanted) == 0 && depth > 0 {
			more = 1 + below(g, 2)
		}
	}
	if least > max(g.room, 0) {
		return
	}
	for len(wanted) < least + more && len(wanted) < most {
		name := ""
		found_fresh := false
		for retry in 0 ..< 8 {
			cand := draw_key_text(g, blocks[:], len(wanted) + retry)
			if !entry_named(wanted[:], cand) {
				name = cand
				found_fresh = true
				break
			}
		}
		if !found_fresh {
			break
		}
		e := Obj_Entry {
			name  = name,
			parts = make([dynamic]Part, g.scratch),
		}
		for b in blocks {
			if b.additional != rules.NONE {
				append(&e.parts, Part{node = b.additional})
			}
		}
		for p in parts {
			if p.node == rules.NONE {
				continue
			}
			if u, has := g.d.nodes[p.node].unevaluated_properties.?; has {
				append(&e.parts, Part{node = u})
			}
		}
		append(&wanted, e)
	}
	out := make([dynamic]rules.Member_Value, g.scratch)
	for e in wanted {
		if len(out) >= most {
			break
		}
		x, got := draw_value(g, e.parts[:], depth - 1)
		if !got {
			if e.required {
				return
			}
			continue
		}
		append(&out, rules.Member_Value{key = e.name, value = x})
	}
	if len(out) < least {
		return
	}
	return out[:], true
}

@(private = "file")
obj_entry :: proc(g: ^Gen, entries: ^[dynamic]Obj_Entry, name: string, block: ^rules.Object = nil) -> ^Obj_Entry {
	for &e in entries {
		if e.name == name {
			return &e
		}
	}
	e := Obj_Entry{name = name, parts = make([dynamic]Part, g.scratch)}
	if block != nil && block.additional != rules.NONE {
		append(&e.parts, Part{node = block.additional})
	}
	append(entries, e)
	return &entries[len(entries) - 1]
}

@(private = "file")
block_listed :: proc "contextless" (b: ^rules.Object, name: string) -> bool {
	for m in b.members {
		if m.name == name && !m.only_required {
			return true
		}
	}
	return false
}

@(private = "file")
entry_named :: proc "contextless" (entries: []Obj_Entry, name: string) -> bool {
	for e in entries {
		if e.name == name {
			return true
		}
	}
	return false
}

@(private = "file")
entry_present :: proc "contextless" (entries: []Obj_Entry, name: string, depth: int) -> bool {
	for e in entries {
		if e.name == name {
			return e.required || depth > 0
		}
	}
	return false
}

@(private = "file")
draw_key_text :: proc(g: ^Gen, blocks: []^rules.Object, i: int) -> string {
	at := make([dynamic]Part, g.scratch)
	for b in blocks {
		if b.keys != rules.NONE {
			append(&at, Part{node = b.keys})
		}
	}
	if len(at) > 0 {
		if k, ok := draw_value(g, at[:], 0); ok {
			if name, is_text := k.(string); is_text {
				return name
			}
		}
	}
	return fmt.aprintf("k%d", i + 1, allocator = g.scratch)
}

// Mutates one position in `root` to find a value failing exactly one rule of `plan`.
@(private = "file")
break_value :: proc(g: ^Gen, plan: ^check.Plan, root: rules.Value) -> (res: rules.Value, ok: bool) {
	v := clone_val(root, g.scratch)
	at := &v
	for {
		#partial switch &x in at^ {
		case []rules.Value:
			if len(x) > 0 && below(g, 3) != 0 {
				at = &x[below(g, len(x))]
				continue
			}
		case []rules.Member_Value:
			if len(x) > 0 && below(g, 3) != 0 {
				at = &x[below(g, len(x))].value
				continue
			}
		}
		break
	}
	mutants := make([dynamic]rules.Value, g.scratch)
	append(&mutants, rules.Null{}, bool(true), rules.Number_Text{"-1e30"}, rules.Number_Text{"0.5"}, rules.Number_Text{"1e30"})
	append(&mutants, string(""), strings.repeat("x", 300, g.scratch), rules.Value(([]rules.Value)(nil)), rules.Value(([]rules.Member_Value)(nil)))
	#partial switch x in at^ {
	case []rules.Value:
		if len(x) > 0 {
			append(&mutants, x[:len(x) - 1])
			dup := make([]rules.Value, len(x) + 1, g.scratch)
			copy(dup, x)
			dup[len(x)] = x[0]
			append(&mutants, dup)
		}
		ext := make([]rules.Value, len(x) + 1, g.scratch)
		copy(ext, x)
		ext[len(x)] = rules.Null{}
		append(&mutants, ext)
	case []rules.Member_Value:
		for _, i in x {
			wo := make([]rules.Member_Value, len(x) - 1, g.scratch)
			copy(wo[:i], x[:i])
			copy(wo[i:], x[i + 1:])
			append(&mutants, wo)
		}
		ext := make([]rules.Member_Value, len(x) + 1, g.scratch)
		copy(ext, x)
		ext[len(x)] = {key = "stray", value = rules.Null{}}
		append(&mutants, ext)
	case string:
		append(&mutants, strings.concatenate({x, x, "x"}, g.scratch))
	}
	for len(mutants) > 0 {
		idx := below(g, len(mutants))
		old := at^
		at^ = mutants[idx]
		unordered_remove(&mutants, idx)
		if fails_alone(g, plan, v) {
			return v, true
		}
		at^ = old
	}
	return {}, false
}

// Shallow-to-deep clone of programmatic `rules.Value` into `allocator` so `break_value` can mutate safely.
@(private = "file")
clone_val :: proc(v: rules.Value, allocator: runtime.Allocator, depth := 0) -> rules.Value {
	if depth > 64 {
		return v
	}
	#partial switch x in v {
	case []rules.Value:
		cp := make([]rules.Value, len(x), allocator)
		for e, i in x {
			cp[i] = clone_val(e, allocator, depth + 1)
		}
		return cp
	case []rules.Member_Value:
		cp := make([]rules.Member_Value, len(x), allocator)
		for m, i in x {
			cp[i] = {key = m.key, value = clone_val(m.value, allocator, depth + 1)}
		}
		return cp
	}
	return v
}
