package schema

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "../regex"
import "../spell"
import core "../"
import "../rules"
import "../typed"
import "../write"

// The values that pass a description are drawn as `core.Value`s in a scratch arena, written in the format asked for and
// checked by the description's own check. A draw that fails the check is dropped for another, so the answer is
// `No_Sample` only after the tries are spent.

// What `sample` draws and how. The zero value gives one valid value from seed 0.
Sample_Options :: struct {
	seed:          u64,
	// How many values to give, 1 when 0.
	count:         int,
	// How deep the optional parts of a value reach, 4 when 0.
	depth:         int,
	// How many draws are made for each value before giving up, 64 when 0.
	tries:         int,
	// The most values and text characters one draw may hold, 65536 when 0. A description that asks for more has no
	// sample.
	size:          int,
	// Values that fail the check, each by one change to a value that passes, so that it fails one rule alone.
	invalid:       bool,
	// A node's `description` is written as a comment where the format has comments.
	comments:      bool,
	// Formats assert, as `check --format-assert` does, so a format with no grammar here has no sample. While `sample`
	// runs the description's nodes say so.
	format_assert: bool,
	// How the values are laid out.
	write:         core.Write_Options,
}

// A node that a position must pass, and rules from a member's use that it must pass too.
@(private = "file")
Part :: struct {
	node:  rules.Node_Index,
	extra: ^rules.Rules,
}

@(private = "file")
Gen :: struct {
	d:        ^rules.Description,
	source:   regex.Source,
	// How much longer than its least a repeat or a text may be, grown with each failed try.
	extra:    int,
	// The values and characters this draw may still hold.
	room:     int,
	// The node the innermost failed draw of this try was for, `NONE` when none failed.
	culprit:  rules.Node_Index,
	comments: bool,
}

// Writes values that pass `d` in the format `as`, as many as `opts.count` says. A description that no value passes
// is `.No_Sample` naming the node the search stopped at by its keyword path, which `allocator` holds, and one the check
// cannot judge is the check's own refusal.
sample :: proc(d: ^rules.Description, as: core.As, opts := Sample_Options{}, allocator := context.allocator) -> (out: [][]u8, err: core.Error) {
	asserted := asserting(d, opts.format_assert)
	defer asserted_restore(d, asserted)
	c := compile_description(d)
	defer destroy(&c)
	b := bind(&c, as) or_return
	defer unbind(&b)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, core.error_of(core.Typed_Error{kind = .No_Memory})
	}
	defer virtual.arena_destroy(&arena)
	g := Gen {
		d        = d,
		source   = {opts.seed},
		comments = opts.comments,
	}
	list := make([dynamic][]u8, allocator)
	for len(list) < max(opts.count, 1) {
		virtual.arena_free_all(&arena)
		text, ok := value_text(&g, &b, as, opts, virtual.arena_allocator(&arena), allocator)
		if !ok {
			for t in list {
				delete(t, allocator)
			}
			delete(list)
			return nil, no_sample(&g, allocator)
		}
		append(&list, text)
	}
	return list[:], nil
}

// The `.No_Sample` that names the node `g` stopped at, by its keyword path from the root.
@(private = "file")
no_sample :: proc(g: ^Gen, allocator: runtime.Allocator) -> core.Error {
	e := core.Typed_Error {
		kind = .No_Sample,
	}
	at := g.culprit if g.culprit != rules.NONE else g.d.root
	steps := make([dynamic]core.Step, context.temp_allocator)
	search := Path_Search {
		d      = g.d,
		target = at,
		steps  = &steps,
		seen   = make([]bool, len(g.d.nodes), context.temp_allocator),
	}
	if reaches(&search, g.d.root) {
		kept := steps[max(0, len(steps) - core.MAX_ERROR_STEPS):]
		e.n_steps, e.truncated = u8(len(kept)), len(kept) < len(steps)
		copy(e.steps[:], kept)
	}
	return core.error_of(e, allocator)
}

// A search of a description's nodes for the keywords that lead to one.
@(private = "file")
Path_Search :: struct {
	d:      ^rules.Description,
	target: rules.Node_Index,
	steps:  ^[dynamic]core.Step,
	seen:   []bool,
}

@(private = "file", rodata)
ARM_WORDS := [3]string{"allOf", "anyOf", "oneOf"}

@(private = "file", rodata)
SINGLE_WORDS := [6]string{"not", "if", "then", "else", "unevaluatedItems", "unevaluatedProperties"}

// Whether node `at` is the target or holds it, with the steps to it in `s.steps`.
@(private = "file")
reaches :: proc(s: ^Path_Search, at: rules.Node_Index) -> bool {
	if at == s.target {
		return true
	}
	if at == rules.NONE || s.seen[at] {
		return false
	}
	s.seen[at] = true
	n := &s.d.nodes[at]
	if r, ok := n.ref.?; ok && through(s, r, core.Name("$ref")) {
		return true
	}
	if r, ok := n.dynamic_ref.?; ok && through(s, r, core.Name("$dynamicRef")) {
		return true
	}
	for arms, word in ([3][]rules.Node_Index{n.all_of, n.any_of, n.one_of}) {
		for x, i in arms {
			if through(s, x, core.Name(ARM_WORDS[word]), core.Index(i)) {
				return true
			}
		}
	}
	for x, word in ([?]Maybe(rules.Node_Index){n.not, n.cond.test, n.cond.then, n.cond.other, n.unevaluated_items, n.unevaluated_properties}) {
		if x, ok := x.?; ok && through(s, x, core.Name(SINGLE_WORDS[word])) {
			return true
		}
	}
	if n.array >= 0 {
		a := &s.d.arrays[n.array]
		for x, i in a.prefix {
			if through(s, x, core.Name("prefixItems"), core.Index(i)) {
				return true
			}
		}
		if through(s, a.items, core.Name("items")) {
			return true
		}
		if c, ok := a.contains.?; ok && through(s, c, core.Name("contains")) {
			return true
		}
	}
	if n.object >= 0 {
		o := &s.d.objects[n.object]
		for m in o.members {
			if through(s, m.node, core.Name("properties"), core.Name(m.name)) {
				return true
			}
		}
		for p in o.patterns {
			if through(s, p.node, core.Name("patternProperties"), core.Name(p.expression)) {
				return true
			}
		}
		if through(s, o.additional, core.Name("additionalProperties")) || through(s, o.keys, core.Name("propertyNames")) {
			return true
		}
	}
	return false
}

// Whether the target is at `node` reached by `steps`, which are left in the path when it is.
@(private = "file")
through :: proc(s: ^Path_Search, node: rules.Node_Index, steps: ..core.Step) -> bool {
	if node == rules.NONE {
		return false
	}
	before := len(s.steps)
	append(s.steps, ..steps)
	if reaches(s, node) {
		return true
	}
	resize(s.steps, before)
	return false
}

// The text of one value: drawn, or for an invalid one, drawn and broken, and written. `ok` is false when no draw in
// the tries passed.
@(private = "file")
value_text :: proc(g: ^Gen, b: ^Bound, as: core.As, opts: Sample_Options, scratch, allocator: runtime.Allocator) -> (text: []u8, ok: bool) {
	context.allocator = scratch
	depth := opts.depth if opts.depth > 0 else 4
	for attempt in 0 ..< (opts.tries if opts.tries > 0 else 64) {
		g.extra = attempt / 4
		g.room = opts.size if opts.size > 0 else 1 << 16
		g.culprit = rules.NONE
		v, drawn := draw(g, {{node = g.d.root}}, depth)
		if !drawn {
			continue
		}
		if opts.invalid {
			text, ok = broken(g, b, as, &v, opts, allocator)
		} else if text, ok = written(v, as, opts, allocator); ok && (len(text) == 0 || !valid(b, text)) {
			delete(text, allocator)
			ok = false
		}
		if ok {
			return
		}
	}
	return nil, false
}

// `v` written in `as`, the bytes in `allocator`.
@(private = "file")
written :: proc(v: core.Value, as: core.As, opts: Sample_Options, allocator: runtime.Allocator) -> (text: []u8, ok: bool) {
	t: write.Tokens
	if write.tokens_init(&t, as, opts.write, allocator = allocator) != .None {
		return nil, false
	}
	if t.spell.line != nil {
		emit_rows(&t, v)
	} else {
		write.value_of(&t, v, true)
	}
	bytes, err := write.tokens_finish(&t)
	return bytes, err.kind == .None
}

// A flat format's text: a record of the member names of the first row, then each row's values in that order, and
// an empty slot for a value that is nested or absent. A value that is not an array is a table of one row.
@(private = "file")
emit_rows :: proc(t: ^write.Tokens, v: core.Value) {
	one := [1]core.Value{core.plain(v)}
	rows := one[:]
	if array, is_array := one[0].(^core.Array); is_array {
		rows = array.items[:]
	}
	if len(rows) == 0 {
		return
	}
	first, is_object := core.plain(rows[0]).(^core.Object)
	if !is_object {
		return
	}
	for k in first.keys {
		write.value_string(t, k)
	}
	write.end_record(t)
	for row in rows {
		object, _ := core.plain(row).(^core.Object)
		for k in first.keys {
			slot: core.Value = ""
			for i in 0 ..< (len(object.keys) if object != nil else 0) {
				#partial switch x in core.plain(object.vals[i]) {
				case ^core.Array, ^core.Object:
				case:
					if object.keys[i] == k {
						slot = x
					}
				}
			}
			write.value_of(t, slot, true)
		}
		write.end_record(t)
	}
}

// `v` with the `description` `note` written on it as a comment, when comments are asked for.
@(private = "file")
commented :: proc(g: ^Gen, v: core.Value, note: string) -> core.Value {
	if !g.comments || note == "" {
		return v
	}
	c := new(core.Commented)
	c.v, c.kind, c.written = v, core.kind(v), {.Comment}
	c.bodies[.Comment] = make([]string, 1)
	c.bodies[.Comment][0] = note
	return c
}

// Whether the draws spend `n` of what one draw may hold.
@(private = "file")
spend :: proc(g: ^Gen, n: int) -> bool {
	g.room -= n
	return g.room >= 0
}

// A number below `n`, which is above 0.
@(private = "file")
below :: proc(g: ^Gen, n: int) -> int {
	return regex.random_below(&g.source, n)
}

// Whether a node with the kinds `k` takes a value of kind `of`: `Number` takes the integers.
@(private = "file")
takes :: proc(k: rules.Kinds, of: rules.Kind) -> bool {
	return of in k || (of == .Integer && .Number in k)
}

// Adds the parts that judge the same value as `p` does, with the arm of each choice taken at random: what a reference
// reaches, `allOf`, one arm of `anyOf` and of `oneOf`, and either branch of a condition. `false` for a chain of
// references that does not end.
@(private = "file")
flatten :: proc(g: ^Gen, out: ^[dynamic]Part, p: Part, hops: int) -> bool {
	if p.node == rules.NONE {
		return true
	}
	if hops > 32 {
		return false
	}
	append(out, p)
	n := &g.d.nodes[p.node]
	if r, ok := n.ref.?; ok && !flatten(g, out, {node = r}, hops + 1) {
		return false
	}
	if r, ok := n.dynamic_ref.?; ok && !flatten(g, out, {node = r}, hops + 1) {
		return false
	}
	for a in n.all_of {
		if !flatten(g, out, {node = a}, hops + 1) {
			return false
		}
	}
	for arms in ([2][]rules.Node_Index{n.any_of, n.one_of}) {
		if len(arms) > 0 && !flatten(g, out, {node = arms[below(g, len(arms))]}, hops + 1) {
			return false
		}
	}
	if test, ok := n.cond.test.?; ok {
		then, has_then := n.cond.then.?
		other, has_other := n.cond.other.?
		// Without an `else` the other branch holds nothing, and the check refuses a draw that passes the test.
		if below(g, 2) == 0 {
			if !flatten(g, out, {node = test}, hops + 1) || has_then && !flatten(g, out, {node = then}, hops + 1) {
				return false
			}
		} else if has_other && !flatten(g, out, {node = other}, hops + 1) {
			return false
		}
	}
	return true
}

// A value that passes every part, or false. The kind is one that every part takes, and its rules are those of
// the parts and their extras.
@(private = "file")
draw :: proc(g: ^Gen, given: []Part, depth: int) -> (v: core.Value, ok: bool) {
	v, ok = draw_parts(g, given, depth)
	if !ok && g.culprit == rules.NONE {
		for p in given {
			g.culprit = p.node if p.node != rules.NONE else g.culprit
		}
	}
	return
}

@(private = "file")
draw_parts :: proc(g: ^Gen, given: []Part, depth: int) -> (v: core.Value, ok: bool) {
	if depth < -6 || !spend(g, 1) {
		return
	}
	all: [dynamic]Part
	for p in given {
		if p.extra != nil {
			append(&all, p)
		}
		if !flatten(g, &all, p, 0) {
			return
		}
	}
	for p in all {
		if p.node == rules.NONE {
			continue
		}
		n := &g.d.nodes[p.node]
		if c, has := n.const_of.?; has {
			return commented(g, c, note_of(g, all[:])), true
		}
		if n.has_enum {
			if len(n.enum_of) == 0 {
				return
			}
			return commented(g, n.enum_of[below(g, len(n.enum_of))], note_of(g, all[:])), true
		}
	}
	candidates: [rules.Kind]bool
	count := 0
	for k in rules.Kind {
		candidates[k] = depth > 0 || k != .Array && k != .Object
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
	list: [dynamic]^rules.Rules
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
		v, ok = nil, true
	case .Bool:
		v, ok = below(g, 2) == 0, true
	case .Integer, .Number:
		v, ok = number(g, list[:], kind == .Integer)
	case .String:
		v, ok = text(g, list[:])
	case .Array:
		v, ok = array(g, list[:], all[:], depth)
	case .Object:
		v, ok = object(g, all[:], list[:], depth)
	}
	if ok {
		v = commented(g, v, note_of(g, given))
	}
	return
}

// The `description` of the first of `parts` that has one.
@(private = "file")
note_of :: proc(g: ^Gen, parts: []Part) -> string {
	for p in parts {
		if p.node != rules.NONE && g.d.nodes[p.node].description != "" {
			return g.d.nodes[p.node].description
		}
	}
	return ""
}

// A number inside the bounds of every rule, a multiple of the first `multipleOf`, and an integer when `whole` or when
// a node takes integers only as spelled.
@(private = "file")
number :: proc(g: ^Gen, list: []^rules.Rules, whole: bool) -> (v: core.Value, ok: bool) {
	lo, hi := math.inf_f64(-1), math.inf_f64(1)
	low_open, high_open := false, false
	step := ""
	for r in list {
		if r.minimum != "" {
			x, _ := strconv.parse_f64(r.minimum)
			if x > lo || x == lo && r.exclusive_minimum {
				lo, low_open = x, r.exclusive_minimum
			}
		}
		if r.maximum != "" {
			x, _ := strconv.parse_f64(r.maximum)
			if x < hi || x == hi && r.exclusive_maximum {
				hi, high_open = x, r.exclusive_maximum
			}
		}
		if step == "" {
			step = r.multiple_of
		}
	}
	if math.is_inf(lo) && math.is_inf(hi) {
		lo, hi = -100, 1000
	} else if math.is_inf(lo) {
		lo = hi - 1000
	} else if math.is_inf(hi) {
		hi = lo + 1000
	}
	if lo > hi || lo == hi && (low_open || high_open) {
		return
	}
	if step != "" {
		return stepped(g, step, lo, hi, low_open, high_open, whole)
	}
	if whole {
		first, last := math.ceil(lo), math.floor(hi)
		first += 1 if low_open && first == lo else 0
		last -= 1 if high_open && last == hi else 0
		if first > last {
			return {}, false
		}
		return core.number_text(fmt.aprintf("%d", i64(first) + i64(below(g, int(min(last - first, 1e6) + 1))))), true
	}
	x := lo + (hi - lo) * (0.1 + 0.8 * f64(below(g, 1000)) / 1000)
	digits: [spell.F64_ROOM]u8
	return core.number_text(strings.clone(string(digits[:spell.f64_text(&digits[0], math.round(x * 100) / 100 if hi - lo >= 1 else x)]))), true
}

// A multiple of `step` between the bounds, spelled exactly: the digits of the step times a whole number, with its
// exponent.
@(private = "file")
stepped :: proc(g: ^Gen, step: string, lo, hi: f64, low_open, high_open, whole: bool) -> (v: core.Value, ok: bool) {
	d := spell.decimal_of(step)
	digits := strings.concatenate({d.head, d.tail}, context.temp_allocator)
	mantissa, parsed := strconv.parse_u64(digits)
	if !parsed || mantissa == 0 || len(digits) > 18 || d.saturated {
		return
	}
	exp := int(d.point) - len(digits)
	unit := f64(mantissa) * math.pow(10, f64(exp))
	first, last := math.ceil(lo / unit), math.floor(hi / unit)
	first += 1 if low_open && first * unit == lo else 0
	last -= 1 if high_open && last * unit == hi else 0
	stride := i128(1)
	for whole && exp < 0 && stride * i128(mantissa) % pow10(-exp) != 0 {
		if stride += 1; stride > 1e6 {
			return
		}
	}
	first = math.ceil(first / f64(stride))
	last = math.floor(last / f64(stride))
	if first > last {
		return
	}
	k := (i128(first) + i128(below(g, int(min(last - first, 1e6) + 1)))) * stride
	return core.number_text(fmt.aprintf("%d", k * i128(mantissa)) if exp == 0 else fmt.aprintf("%de%d", k * i128(mantissa), exp)), true
}

@(private = "file")
pow10 :: proc(n: int) -> i128 {
	x := i128(1)
	for _ in 0 ..< min(n, 36) {
		x *= 10
	}
	return x
}

// A string of the length every rule allows, matching the first `pattern` and spelled as the first `format`.
@(private = "file")
text :: proc(g: ^Gen, list: []^rules.Rules) -> (v: core.Value, ok: bool) {
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
			s = regex.sample(pattern, &g.source, g.extra + tries, least) or_return
		case format != "" && format_text(g, format) != "":
			s = format_text(g, format)
		case:
			s = letters(g, max(int(lo), 1 if hi > 0 else 0) + below(g, 1 + int(min(hi - lo, u64(4 + g.extra)))))
		}
		if n := u64(utf8.rune_count_in_string(s)); n >= lo && n <= hi && spend(g, int(n)) {
			return s, true
		}
		if pattern == "" {
			return
		}
	}
	return
}

@(private = "file")
letters :: proc(g: ^Gen, n: int) -> string {
	b := make([]u8, n)
	for &c in b {
		c = u8('a' + below(g, 26))
	}
	return string(b)
}

// A text of the grammar the format `name` has, or "" for one that is not known.
@(private = "file")
format_text :: proc(g: ^Gen, name: string) -> string {
	switch name {
	case "date-time":
		return fmt.aprintf("20%02d-%02d-%02dT%02d:%02d:%02dZ", below(g, 100), 1 + below(g, 12), 1 + below(g, 28), below(g, 24), below(g, 60), below(g, 60))
	case "date":
		return fmt.aprintf("20%02d-%02d-%02d", below(g, 100), 1 + below(g, 12), 1 + below(g, 28))
	case "time":
		return fmt.aprintf("%02d:%02d:%02dZ", below(g, 24), below(g, 60), below(g, 60))
	case "email", "idn-email":
		return fmt.aprintf("%s@%s.com", letters(g, 5), letters(g, 5))
	case "hostname", "idn-hostname":
		return fmt.aprintf("%s.example.com", letters(g, 5))
	case "ipv4":
		return fmt.aprintf("%d.%d.%d.%d", below(g, 256), below(g, 256), below(g, 256), below(g, 256))
	case "ipv6":
		return fmt.aprintf("2001:db8::%x:%x", below(g, 65536), below(g, 65536))
	case "uri", "iri":
		return fmt.aprintf("https://%s.example.com/%s", letters(g, 5), letters(g, 4))
	case "uuid":
		return fmt.aprintf("%08x-%04x-4%03x-8%03x-%012x", regex.random_next(&g.source) & 0xffffffff, regex.random_next(&g.source) & 0xffff, regex.random_next(&g.source) & 0xfff, regex.random_next(&g.source) & 0xfff, regex.random_next(&g.source) & 0xffffffffffff)
	case "json-pointer":
		return fmt.aprintf("/%s/%d", letters(g, 4), below(g, 10))
	case "relative-json-pointer":
		return fmt.aprintf("%d/%s", below(g, 10), letters(g, 4))
	case "duration":
		return fmt.aprintf("P%dDT%dH", below(g, 30), below(g, 24))
	case "uri-reference", "iri-reference":
		return fmt.aprintf("/%s/%s", letters(g, 4), letters(g, 4))
	case "uri-template":
		return fmt.aprintf("https://example.com/%s/{%s}", letters(g, 4), letters(g, 3))
	case "regex":
		return fmt.aprintf("^%s[0-9]+$", letters(g, 3))
	}
	return ""
}

// An array of the length every node allows. An element passes the node a position names: the prefix node of each
// block that has one there, else its `items`, and the `contains` node for the first elements that must pass it.
@(private = "file")
array :: proc(g: ^Gen, list: []^rules.Rules, parts: []Part, depth: int) -> (v: core.Value, ok: bool) {
	lo, hi, unique := u64(0), max(u64), false
	for r in list {
		lo, hi, unique = max(lo, r.min_items), min(hi, r.max_items.? or_else max(u64)), unique || r.unique
	}
	need, most := u64(0), max(u64)
	blocks: [dynamic]^rules.Array
	for p in parts {
		if p.node == rules.NONE || g.d.nodes[p.node].array < 0 {
			continue
		}
		a := &g.d.arrays[g.d.nodes[p.node].array]
		append(&blocks, a)
		if _, has := a.contains.?; has {
			need = max(need, a.min_contains.? or_else 1)
			most = min(most, a.max_contains.? or_else max(u64))
		}
	}
	lo = max(lo, need)
	if lo > hi || need > most || lo > u64(max(g.room, 0)) {
		return
	}
	n := min(hi, lo + u64(below(g, 3 + g.extra))) if depth > 0 else lo
	items := make([dynamic]core.Value)
	for i in 0 ..< int(n) {
		at: [dynamic]Part
		for a in blocks {
			if i < len(a.prefix) {
				append(&at, Part{node = a.prefix[i]})
			} else if a.items != rules.NONE {
				append(&at, Part{node = a.items})
			}
			if c, has := a.contains.?; has && u64(i) < need {
				append(&at, Part{node = c})
			}
		}
		e: core.Value
		got: bool
		for _ in 0 ..< (6 if unique else 1) {
			if e, got = draw(g, at[:], depth - 1); got && !(unique && repeated(items[:], e)) {
				break
			}
		}
		if !got {
			if u64(i) < lo {
				return
			}
			break
		}
		append(&items, e)
	}
	if u64(len(items)) < lo {
		return
	}
	return array_of(items), true
}

@(private = "file")
array_of :: proc(items: [dynamic]core.Value) -> ^core.Array {
	a := new(core.Array)
	a.items = items
	return a
}

@(private = "file")
object_of :: proc(keys: [dynamic]string, vals: [dynamic]core.Value) -> ^core.Object {
	o := new(core.Object)
	o.keys, o.vals = keys, vals
	return o
}

// Whether `e` is the same value as one of `items`, or, when it repeats one that `unique` says, is not.
@(private = "file")
repeated :: proc(items: []core.Value, e: core.Value) -> bool {
	for x in items {
		if core.equal(x, e) {
			return true
		}
	}
	return false
}

// An entry of an object being drawn: a name, the parts its value passes, and whether it must be there.
@(private = "file")
Entry :: struct {
	name:     string,
	parts:    [dynamic]Part,
	required: bool,
}

// An object with every required member, the optional ones that depth allows, and the members that `minProperties`
// asks for. A name that a block of `parts` lists passes that block's member node and, where another block does not
// list it, that block's `additionalProperties`.
@(private = "file")
object :: proc(g: ^Gen, parts: []Part, list: []^rules.Rules, depth: int) -> (v: core.Value, ok: bool) {
	blocks: [dynamic]^rules.Object
	entries: [dynamic]Entry
	for p in parts {
		if p.node != rules.NONE && g.d.nodes[p.node].object >= 0 {
			append(&blocks, &g.d.objects[g.d.nodes[p.node].object])
		}
	}
	for b in blocks {
		for &m in b.members {
			e := entry(&entries, m.name)
			e.required ||= m.required
			if !m.only_required {
				append(&e.parts, Part{node = m.node, extra = &m.rules})
			}
		}
	}
	for &e in entries {
		for b in blocks {
			if !listed(b, e.name) && b.additional != rules.NONE {
				append(&e.parts, Part{node = b.additional})
			}
		}
	}
	for _ in 0 ..< 4 {
		for b in blocks {
			for dep in b.dependents {
				if present(entries[:], dep.name, depth) {
					for name in dep.required {
						entry(&entries, name, b).required = true
					}
				}
			}
		}
	}
	least, most := 0, max(int)
	for r in list {
		least, most = max(least, int(r.min_members)), min(most, int(r.max_members.? or_else u64(max(int))))
	}
	wanted := make([dynamic]Entry)
	for &e in entries {
		if e.required || depth > 0 && below(g, 2) == 0 || len(wanted) + (len(entries) - len(wanted)) <= least {
			append(&wanted, e)
		}
	}
	more := 0
	for b in blocks {
		for p in b.patterns {
			if (len(wanted) < least || below(g, 2) == 0) && depth > 0 {
				if name, sampled := regex.sample(p.expression, &g.source, g.extra, 0); sampled && !named(wanted[:], name) {
					e := Entry {
						name = name,
					}
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
		e := Entry {
			name = key_text(g, blocks[:], len(wanted)),
		}
		for b in blocks {
			if b.additional != rules.NONE {
				append(&e.parts, Part{node = b.additional})
			}
		}
		if named(wanted[:], e.name) {
			break
		}
		append(&wanted, e)
	}
	items, keys := make([dynamic]core.Value), make([dynamic]string)
	for e in wanted {
		if len(items) >= most {
			break
		}
		x, got := draw(g, e.parts[:], depth - 1)
		if !got {
			if e.required {
				return
			}
			continue
		}
		append(&items, x)
		append(&keys, e.name)
	}
	if len(items) < least {
		return
	}
	return object_of(keys, items), true
}

@(private = "file")
entry :: proc(entries: ^[dynamic]Entry, name: string, block: ^rules.Object = nil) -> ^Entry {
	for &e in entries {
		if e.name == name {
			return &e
		}
	}
	e := Entry {
		name = name,
	}
	if block != nil && block.additional != rules.NONE {
		append(&e.parts, Part{node = block.additional})
	}
	append(entries, e)
	return &entries[len(entries) - 1]
}

@(private = "file")
listed :: proc(b: ^rules.Object, name: string) -> bool {
	for m in b.members {
		if m.name == name && !m.only_required {
			return true
		}
	}
	return false
}

@(private = "file")
named :: proc(entries: []Entry, name: string) -> bool {
	for e in entries {
		if e.name == name {
			return true
		}
	}
	return false
}

// Whether `name` is an entry that is, or may be, drawn.
@(private = "file")
present :: proc(entries: []Entry, name: string, depth: int) -> bool {
	for e in entries {
		if e.name == name {
			return e.required || depth > 0
		}
	}
	return false
}

// A member name for the `i`th extra member: a string every `propertyNames` node of the blocks takes, else `k` and
// the number.
@(private = "file")
key_text :: proc(g: ^Gen, blocks: []^rules.Object, i: int) -> string {
	at: [dynamic]Part
	for b in blocks {
		if b.keys != rules.NONE {
			append(&at, Part{node = b.keys})
		}
	}
	if len(at) > 0 {
		if k, ok := draw(g, at[:], 0); ok {
			if name, is_text := core.plain(k).(string); is_text {
				return name
			}
		}
	}
	return fmt.aprintf("k%d", i + 1)
}

// A text of a value that does not pass: a valid draw with one part changed to something that fails the check, and
// fails it on one rule alone. The changes tried are those of kind, size and shape of the value drawn, in random
// order.
@(private = "file")
broken :: proc(g: ^Gen, b: ^Bound, as: core.As, v: ^core.Value, opts: Sample_Options, allocator: runtime.Allocator) -> (text: []u8, ok: bool) {
	at := v
	for {
		items, is_array := core.plain(at^).(^core.Array)
		object, is_object := core.plain(at^).(^core.Object)
		switch {
		case is_array && len(items.items) > 0 && below(g, 3) != 0:
			at = &items.items[below(g, len(items.items))]
			continue
		case is_object && len(object.vals) > 0 && below(g, 3) != 0:
			at = &object.vals[below(g, len(object.vals))]
			continue
		}
		break
	}
	mutants: [dynamic]core.Value
	append(&mutants, nil, true, core.number_text("-1e30"), core.number_text("0.5"), core.number_text("1e30"))
	append(&mutants, "", strings.repeat("x", 300), array_of({}), object_of({}, {}))
	#partial switch x in core.plain(at^) {
	case ^core.Array:
		if len(x.items) > 0 {
			append(&mutants, array_of(slice_dynamic(x.items[:len(x.items) - 1])), array_of(with(x.items[:], x.items[0])))
		}
		append(&mutants, array_of(with(x.items[:], nil)))
	case ^core.Object:
		for _, i in x.vals {
			append(&mutants, object_of(without(x.keys[:], i), without(x.vals[:], i)))
		}
		append(&mutants, object_of(with(x.keys[:], "stray"), with(x.vals[:], nil)))
	case string:
		append(&mutants, strings.concatenate({x, x, "x"}))
	}
	for len(mutants) > 0 {
		i := below(g, len(mutants))
		old := at^
		at^ = commented(g, mutants[i], note_text(old))
		unordered_remove(&mutants, i)
		if text, ok = written(v^, as, opts, allocator); ok {
			if len(text) > 0 && fails_alone(b, text) {
				return
			}
			delete(text, allocator)
		}
		at^ = old
	}
	return nil, false
}

// The `description` written on `v` as a comment, "" for none.
@(private = "file")
note_text :: proc(v: core.Value) -> string {
	if c, is_commented := v.(^core.Commented); is_commented && len(c.bodies[.Comment]) > 0 {
		return c.bodies[.Comment][0]
	}
	return ""
}

// Whether the check of `text` has exactly one failure.
@(private = "file")
fails_alone :: proc(b: ^Bound, text: []u8) -> bool {
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	return check(b, text, &sink) != nil && len(sink.entries) == 1
}

@(private = "file")
slice_dynamic :: proc(xs: []$T) -> [dynamic]T {
	out := make([dynamic]T, 0, len(xs) + 1)
	append(&out, ..xs)
	return out
}

@(private = "file")
with :: proc(xs: []$T, x: T) -> [dynamic]T {
	out := slice_dynamic(xs)
	append(&out, x)
	return out
}

@(private = "file")
without :: proc(xs: []$T, i: int) -> [dynamic]T {
	out := make([dynamic]T, 0, len(xs))
	append(&out, ..xs[:i])
	append(&out, ..xs[i + 1:])
	return out
}
