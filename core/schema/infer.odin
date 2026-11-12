package schema

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import "../spell"
import core "../"
import "../rules"
import "../write"
import "../records"

// Inference reads values and keeps, per position, what was seen there. It makes no guess: a position takes the kinds it
// met and a member is required when every object at its position had it. Summaries merge, so records are read on
// the threads of a runner and their summaries joined.

// The most distinct member names a position keeps. A position past it, or whose names are all integers or all UUIDs, is
// a map: its members are one value summary.
@(private)
MAX_NAMES :: 64

// The forms a member name may have, which make an object a map when every name has one.
@(private)
Key_Form :: enum u8 {
	Integer,
	Uuid,
}

// What an inference keeps of the values at one position. The counts are of the values of that kind.
@(private)
Summary :: struct {
	kinds:                  rules.Kinds,
	numbers, strings:       u64,
	arrays, objects:        u64,
	// The smallest and largest number, in `low` and `high` once `ranged`.
	low, high:              core.Value,
	ranged:                 bool,
	min_chars, max_chars:   u64,
	min_items, max_items:   u64,
	// The elements of every array, summarised together.
	items:                  ^Summary,
	members:                [dynamic]Member_Seen,
	// The values of every member once `collapsed`.
	values:                 ^Summary,
	collapsed:              bool,
	// The forms that every name seen has.
	forms:                  bit_set[Key_Form],
	// Where the last name was found, since records mostly keep the order of their names.
	hint:                   int,
}

// A member name seen at a position: in how many of its objects, and whether a markup object repeated it.
@(private)
Member_Seen :: struct {
	name:      string,
	count:     u64,
	at:        ^Summary,
	// The object, by its number at the position, that last had the member, and the markup node it had it as.
	last:      u64,
	last_node: rules.Markup_Node,
	// A markup element repeated the name among its children, so the member is an array of the elements.
	collected: bool,
	// An attribute had the name, so a lone value of the member is the attribute's or one child's, and the member is not
	// only an array.
	attributed: bool,
	// The markup node the member is read from: `.Any` once an attribute and a child element of the name were both met.
	markup:    rules.Markup_Node,
	// Where the member first appeared among all the members the inference created, which orders the members of a
	// position by first appearance whatever order the pieces of a text were summarised in.
	ordinal:   u64,
}

// The summary of the values passed to `infer`, which merges with another's. The zero value is ready, and it is not
// copied while a call on it runs. Its memory is an arena that `inferred_destroy` frees. After `.Out_Of_Memory` it is
// only destroyed.
Inferred :: struct {
	root:   ^Summary,
	// Whether to keep the ranges of numbers, string lengths and array lengths.
	ranges: bool,
	// The records are the rows of a flat format, whose text is an array of them. `infer_records` sets it.
	rows:   bool,
	arena:  virtual.Arena,
	failed: bool,
	// The members created so far, which numbers each one's first appearance.
	seq:    u64,
	// Where a write goes once memory is refused, so the walk can end without a branch at each write.
	trash:  Summary,
}

inferred_destroy :: proc(inf: ^Inferred) {
	virtual.arena_destroy(&inf.arena)
	inf^ = {}
}

// Takes in the value `v`, a node of a document or a value built. A markup document's attributes are members, a scalar
// element with attributes is an object whose text is the member `#text`, and a name an element's children repeat is
// one array member. A `Plain` value is the kind its document reads it as.
infer :: proc(inf: ^Inferred, v: core.Value) -> runtime.Allocator_Error {
	if inf.root == nil && !begin(inf) {
		return .Out_Of_Memory
	}
	context.allocator = virtual.arena_allocator(&inf.arena)
	take(inf, inf.root, v)
	return .Out_Of_Memory if inf.failed else .None
}

// Joins the summary `src`, taken after everything `dst` holds, into `dst`. `src` keeps its own memory.
merge :: proc(dst, src: ^Inferred) -> runtime.Allocator_Error {
	if src.failed {
		return .Out_Of_Memory
	}
	if src.root == nil {
		return .None
	}
	if dst.root == nil && !begin(dst) {
		return .Out_Of_Memory
	}
	context.allocator = virtual.arena_allocator(&dst.arena)
	dst.rows ||= src.rows
	join(dst, dst.root, src.root, dst.seq)
	dst.seq += src.seq
	return .Out_Of_Memory if dst.failed else .None
}

@(private = "file")
begin :: proc(inf: ^Inferred) -> bool {
	if virtual.arena_init_growing(&inf.arena) != nil {
		return false
	}
	context.allocator = virtual.arena_allocator(&inf.arena)
	inf.root = fresh(inf)
	return !inf.failed
}

@(private = "file")
fresh :: proc(inf: ^Inferred) -> ^Summary {
	p, err := new(Summary)
	if err != nil {
		inf.failed = true
		return &inf.trash
	}
	p.forms = {.Integer, .Uuid}
	return p
}

@(private = "file")
child :: proc(inf: ^Inferred, p: ^^Summary) -> ^Summary {
	if p^ == nil {
		p^ = fresh(inf)
	}
	return p^
}

@(private = "file")
take :: proc(inf: ^Inferred, p: ^Summary, value: core.Value) {
	v := core.plain(value)
	kind := core.kind(v)
	if ref, ok := v.(core.Node_Ref); ok && kind != .Array && ref.doc.readers != nil && ref.doc.readers.attribute != nil {
		it := core.attributes_of(ref.doc, ref.node)
		if _, _, held := core.attribute_next(&it); held || kind == .Object {
			object(inf, p, v, ref)
			return
		}
	}
	#partial switch kind {
	case .Array:
		array(inf, p, v)
	case .Object:
		object(inf, p, v, {})
	case:
		leaf(inf, p, v, kind)
	}
}

@(private = "file")
leaf :: proc(inf: ^Inferred, p: ^Summary, v: core.Value, kind: core.Kind) {
	#partial switch kind {
	case .Null:
		p.kinds += {.Null}
	case .True, .False:
		p.kinds += {.Bool}
	case .Number:
		number(inf, p, v)
	case .Bytes:
		// A byte string is a string to a schema, and its payload has no length in characters.
		p.kinds += {.String}
	case .String:
		p.kinds += {.String}
		p.strings += 1
		if inf.ranges {
			chars := u64(text_chars(v))
			p.min_chars, p.max_chars = (chars if p.strings == 1 else min(p.min_chars, chars)), max(p.max_chars, chars)
		}
	}
}

@(private = "file")
number :: proc(inf: ^Inferred, p: ^Summary, v: core.Value) {
	n, _ := core.number(v)
	whole := n.kind != .Float && n.kind != .Wide
	if !whole {
		f, digits, _ := core.double_of(v)
		whole = rules.integral(spell.decimal_of(digits)) if digits != "" else f == math.trunc(f) && !math.is_inf(f)
	}
	p.kinds += {.Integer if whole else .Number}
	p.numbers += 1
	if !inf.ranges {
		return
	}
	if !p.ranged || core.compare(v, p.low) < 0 {
		p.low = kept(v)
	}
	if !p.ranged || core.compare(v, p.high) > 0 {
		p.high = kept(v)
	}
	p.ranged = true
}

// A number `v` as a value that outlives its document, in the context allocator.
@(private = "file")
kept :: proc(v: core.Value) -> core.Value {
	#partial switch x in v {
	case ^core.Number_Text:
		return core.number_text(strings.clone(x.text))
	case core.Node_Ref:
		return core.built_value(x)
	}
	return v
}

// The code points of the text of string `v`.
@(private = "file")
text_chars :: proc(v: core.Value) -> int {
	buf: [512]u8
	if ref, ok := v.(core.Node_Ref); ok {
		s, spill := node_text(ref, buf[:])
		defer delete(spill, runtime.heap_allocator())
		return utf8.rune_count_in_string(s)
	}
	s, _ := core.text(v, buf[:])
	return utf8.rune_count_in_string(s)
}

// The text of the string node `ref`, decoded into `buf` when it fits, else into `spill`, which the caller frees.
@(private = "file")
node_text :: proc(ref: core.Node_Ref, buf: []u8) -> (s: string, spill: []u8) {
	if room := core.text_room(ref.doc, ref.node); room > len(buf) {
		spill = make([]u8, room, runtime.heap_allocator())
	}
	s, _ = core.doc_text(ref.doc, ref.node, spill if spill != nil else buf)
	return
}

@(private = "file")
array :: proc(inf: ^Inferred, p: ^Summary, v: core.Value) {
	p.kinds += {.Array}
	p.arrays += 1
	n := u64(core.length(v))
	p.min_items, p.max_items = (n if p.arrays == 1 else min(p.min_items, n)), max(p.max_items, n)
	it := core.children(v)
	for e in core.child_next(&it) {
		take(inf, child(inf, &p.items), e)
	}
}

// An object, or a markup element with attributes, whose `ref` is its node.
@(private = "file")
object :: proc(inf: ^Inferred, p: ^Summary, v: core.Value, ref: core.Node_Ref) {
	p.kinds += {.Object}
	p.objects += 1
	markup := ref.doc != nil
	if markup {
		it := core.attributes_of(ref.doc, ref.node)
		for name, value in core.attribute_next(&it) {
			text, _ := core.token_text(ref.doc.readers, &ref.doc.view, name, context.temp_allocator)
			at := member(inf, p, text, markup, .Attribute)
			at.kinds += {.String}
			at.strings += 1
			if inf.ranges {
				chars := u64(utf8.rune_count_in_string(core.token_text(ref.doc.readers, &ref.doc.view, value, context.temp_allocator) or_else ""))
				at.min_chars, at.max_chars = (chars if at.strings == 1 else min(at.min_chars, chars)), max(at.max_chars, chars)
			}
		}
		if scalar := core.kind(v); scalar != .Object {
			if n := ref.doc.nodes[ref.node]; n.kind != .Null && n.n != 0 {
				leaf(inf, member(inf, p, "#text", markup, .Text), v, scalar)
			}
			return
		}
	}
	it := core.pairs(v)
	buf: [256]u8
	for {
		key: string
		value: core.Value
		if r, is_node := v.(core.Node_Ref); is_node {
			k, n, more := core.doc_pair_next(&it.pairs)
			if !more {
				break
			}
			spill: []u8
			key, spill = node_text({r.doc, k}, buf[:])
			if spill != nil {
				key = strings.clone(key, context.temp_allocator)
				delete(spill, runtime.heap_allocator())
			}
			value = core.Node_Ref{r.doc, n}
		} else {
			more: bool
			key, value, more = core.pair_next(&it)
			if !more {
				break
			}
		}
		take(inf, member(inf, p, key, markup, .Any), value)
	}
}

// The position of the member `name` of an object at `p`, counted once for the object.
@(private = "file")
member :: proc(inf: ^Inferred, p: ^Summary, name: string, markup: bool, node: rules.Markup_Node) -> ^Summary {
	if p.collapsed {
		return child(inf, &p.values)
	}
	p.forms &= forms_of(name)
	found := -1
	for k in 0 ..< len(p.members) {
		i := (p.hint + k) % len(p.members)
		if p.members[i].name == name {
			found = i
			break
		}
	}
	if found < 0 {
		if len(p.members) == MAX_NAMES {
			collapse(inf, p)
			return child(inf, &p.values)
		}
		text := strings.clone(name)
		if _, err := append(&p.members, Member_Seen{name = text, at = fresh(inf), markup = node, ordinal = inf.seq}); err != nil {
			inf.failed = true
			return &inf.trash
		}
		inf.seq += 1
		found = len(p.members) - 1
	}
	m := &p.members[found]
	p.hint = (found + 1) % len(p.members)
	m.attributed ||= node == .Attribute
	if m.last != p.objects {
		m.count, m.last = m.count + 1, p.objects
	} else if node == .Any && m.last_node == .Any {
		m.collected ||= markup
	}
	// An attribute and a child element of one name are one member that reads either, not an array of both.
	if m.markup != node {
		m.markup = .Any
	}
	m.last_node = node
	return m.at
}

@(private = "file")
forms_of :: proc(name: string) -> (forms: bit_set[Key_Form]) {
	digits := name[1:] if strings.has_prefix(name, "-") else name
	if len(digits) > 0 && strings.trim_left(digits, "0123456789") == "" {
		forms += {.Integer}
	}
	if len(name) == 36 && name[8] == '-' && name[13] == '-' && name[18] == '-' && name[23] == '-' {
		uuid := true
		for c, i in transmute([]u8)name {
			uuid &&= i == 8 || i == 13 || i == 18 || i == 23 || '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
		}
		if uuid {
			forms += {.Uuid}
		}
	}
	return
}

// Joins every member of `p` into one summary of values.
@(private = "file")
collapse :: proc(inf: ^Inferred, p: ^Summary) {
	all := child(inf, &p.values)
	for m in p.members {
		join(inf, all, m.at, 0)
	}
	delete(p.members)
	p.members, p.collapsed = nil, true
}

// Adds the summary `src` to `dst`, copying what it keeps into the context allocator. The members of `src` that `dst`
// lacks take their ordinals plus `offset`, the members `dst` already created before them.
@(private = "file")
join :: proc(inf: ^Inferred, dst, src: ^Summary, offset: u64) {
	dst.kinds += src.kinds
	dst.numbers += src.numbers
	if src.ranged {
		if !dst.ranged || core.compare(src.low, dst.low) < 0 {
			dst.low = kept(src.low)
		}
		if !dst.ranged || core.compare(src.high, dst.high) > 0 {
			dst.high = kept(src.high)
		}
		dst.ranged = true
	}
	if src.strings > 0 {
		dst.min_chars, dst.max_chars = (src.min_chars if dst.strings == 0 else min(dst.min_chars, src.min_chars)), max(dst.max_chars, src.max_chars)
		dst.strings += src.strings
	}
	if src.arrays > 0 {
		dst.min_items, dst.max_items = (src.min_items if dst.arrays == 0 else min(dst.min_items, src.min_items)), max(dst.max_items, src.max_items)
		dst.arrays += src.arrays
	}
	if src.items != nil {
		join(inf, child(inf, &dst.items), src.items, offset)
	}
	dst.objects += src.objects
	dst.forms &= src.forms
	if src.collapsed && !dst.collapsed {
		collapse(inf, dst)
	}
	if src.values != nil {
		join(inf, child(inf, &dst.values), src.values, offset)
	}
	for m in src.members {
		if dst.collapsed {
			join(inf, child(inf, &dst.values), m.at, offset)
			continue
		}
		at := -1
		for x, i in dst.members {
			if x.name == m.name {
				at = i
				break
			}
		}
		if at < 0 {
			if len(dst.members) == MAX_NAMES {
				collapse(inf, dst)
				join(inf, child(inf, &dst.values), m.at, offset)
				continue
			}
			if _, err := append(&dst.members, Member_Seen{name = strings.clone(m.name), at = fresh(inf), markup = m.markup, ordinal = m.ordinal + offset}); err != nil {
				inf.failed = true
				return
			}
			at = len(dst.members) - 1
		}
		x := &dst.members[at]
		x.count += m.count
		x.collected ||= m.collected
		x.attributed ||= m.attributed
		x.ordinal = min(x.ordinal, m.ordinal + offset)
		if x.markup != m.markup {
			x.markup = .Any
		}
		join(inf, x.at, m.at, offset)
	}
}

// The description of the values taken in, which every one of them passes. A position that is a map is settled here and
// stays one. Without `inf.ranges` it holds kinds and members only: an integer and a fraction at a position are
// `number`, a member is required when every object at the position had it, a map has `additionalProperties` and no
// members, and the elements of arrays are `items`.
inferred :: proc(inf: ^Inferred, allocator := context.allocator) -> (d: rules.Description, err: runtime.Allocator_Error) {
	d.allocator = allocator
	b := Describer{d = &d, inf = inf}
	root := inf.root if inf.root != nil else &Summary{kinds = rules.EVERY_KIND}
	if inf.rows {
		root = &Summary{kinds = {.Array}, arrays = 1, items = root}
	}
	describe(&b, root)
	if inf.rows && len(d.nodes) > 0 {
		// The rows of every input are one table, whose length no input fixes.
		d.nodes[0].rules.min_items, d.nodes[0].rules.max_items = 0, nil
	}
	if b.failed {
		rules.description_destroy(&d)
		return {}, .Out_Of_Memory
	}
	return d, .None
}

@(private = "file")
Describer :: struct {
	d:      ^rules.Description,
	inf:    ^Inferred,
	failed: bool,
}

// Adds the node of `p` and its children to the description, and returns its index.
@(private = "file")
describe :: proc(b: ^Describer, p: ^Summary) -> rules.Node_Index {
	context.allocator = b.d.allocator
	i := rules.Node_Index(len(b.d.nodes))
	n := rules.Node {
		kinds    = p.kinds if p.kinds != {} else rules.EVERY_KIND,
		array    = -1,
		object   = -1,
		resource = 0,
	}
	if .Number in n.kinds {
		n.kinds -= {.Integer}
	}
	if _, err := append(&b.d.nodes, n); err != nil {
		b.failed = true
		return i
	}
	if b.inf.ranges {
		b.d.nodes[i].rules = ranges_of(b, p)
	}
	if p.arrays > 0 {
		a := rules.Array{items = rules.NONE}
		if p.items != nil {
			a.items = describe(b, p.items)
		}
		b.d.nodes[i].array = i32(len(b.d.arrays))
		_, err := append(&b.d.arrays, a)
		b.failed ||= err != nil
	}
	if p.objects > 0 {
		o := members_of(b, p)
		b.d.nodes[i].object = i32(len(b.d.objects))
		_, err := append(&b.d.objects, o)
		b.failed ||= err != nil
	}
	return i
}

@(private = "file")
members_of :: proc(b: ^Describer, p: ^Summary) -> rules.Object {
	o := rules.Object {
		additional = rules.NONE,
		keys       = rules.NONE,
	}
	if !p.collapsed && len(p.members) > 0 && p.forms != {} {
		context.allocator = virtual.arena_allocator(&b.inf.arena)
		collapse(b.inf, p)
		context.allocator = b.d.allocator
	}
	if p.collapsed {
		if p.values != nil {
			o.additional = describe(b, p.values)
		}
		return o
	}
	list, err := make([]rules.Member, len(p.members))
	b.failed ||= err != nil
	slice.sort_by(p.members[:], proc(x, y: Member_Seen) -> bool {return x.ordinal < y.ordinal})
	for m, k in p.members {
		if err != nil {
			break
		}
		at := describe(b, m.at)
		if m.collected {
			at = collected(b, at, m.attributed)
		}
		b.d.nodes[at].rules.markup = m.markup
		list[k] = {name = text_of(b, m.name), node = at, required = m.count == p.objects}
	}
	o.members = list
	return o
}

// A node for an array of the elements that node `item` takes, or for one of them alone too when `alone`.
@(private = "file")
collected :: proc(b: ^Describer, item: rules.Node_Index, alone: bool) -> rules.Node_Index {
	at := rules.Node_Index(len(b.d.nodes))
	n := rules.Node {
		kinds    = {.Array},
		array    = i32(len(b.d.arrays)),
		object   = -1,
		resource = 0,
	}
	_, e1 := append(&b.d.nodes, n)
	_, e2 := append(&b.d.arrays, rules.Array{items = item})
	b.failed ||= e1 != nil || e2 != nil
	if !alone {
		return at
	}
	arms, e3 := make([]rules.Node_Index, 2)
	arms[0], arms[1] = item, at
	wrapper := rules.Node_Index(len(b.d.nodes))
	_, e4 := append(&b.d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, any_of = arms})
	b.failed ||= e3 != nil || e4 != nil
	return wrapper
}

// The description's own copy of `s`.
@(private = "file")
text_of :: proc(b: ^Describer, s: string) -> string {
	t := strings.clone(s, b.d.allocator)
	_, err := append(&b.d.texts, t)
	b.failed ||= err != nil
	return t
}

@(private = "file")
ranges_of :: proc(b: ^Describer, p: ^Summary) -> (r: rules.Rules) {
	if p.ranged {
		r.minimum, r.maximum = number_text(b, p.low), number_text(b, p.high)
	}
	if p.strings > 0 {
		r.min_length, r.max_length = p.min_chars, p.max_chars
	}
	if p.arrays > 0 {
		r.min_items, r.max_items = p.min_items, p.max_items
	}
	return
}

// The JSON number a bound spells, "" for a bound no JSON number spells.
@(private = "file")
number_text :: proc(b: ^Describer, v: core.Value) -> string {
	#partial switch x in v {
	case ^core.Number_Text:
		return text_of(b, x.text)
	case f64:
		if math.is_inf(x) || math.is_nan(x) {
			return ""
		}
		digits: [spell.F64_ROOM]u8
		return text_of(b, string(digits[:spell.f64_text(&digits[0], x)]))
	}
	return ""
}

// What a runner's threads gather: a summary per piece, joined in source order.
@(private = "file")
Piece_Sums :: struct {
	lock:    sync.Mutex,
	sums:    [dynamic]^Inferred,
	ranges:  bool,
	rows:    bool,
	failed:  bool,
	// The first record, by its piece, that did not build or whose summary ran out of memory.
	bad:     core.Error,
	bad_at:  int,
	// The first piece whose records ended on a fault of the text.
	fault_at: int,
}

// Takes in every record of `src` in format `as` under `framing`, on the threads of `runner` when it has any. A record
// whose text does not read ends the records, and that fault is the result, with the records before it taken in. The
// summary is the one a single thread would make.
infer_records :: proc(inf: ^Inferred, src: []u8, as: core.As, framing := core.Framing.Lines, runner: ^core.Runner = nil) -> core.Error {
	inf.rows ||= flat(as)
	sums := Piece_Sums {
		ranges   = inf.ranges,
		rows     = inf.rows,
		bad_at   = max(int),
		fault_at = max(int),
	}
	heap := runtime.heap_allocator()
	sums.sums.allocator = heap
	defer delete(sums.sums)
	err := records.each(src, as, framing, infer_piece, &sums, runner)
	if sums.bad != nil && (err == nil || sums.bad_at <= sums.fault_at) {
		err = sums.bad
	}
	for s, k in sums.sums {
		if s == nil {
			continue
		}
		// The pieces past a fault hold records that are no records of the text.
		if k <= sums.bad_at && merge(inf, s) != .None && err == nil {
			err = core.error_of(core.Typed_Refusal{kind = .No_Memory})
		}
		inferred_destroy(s)
		free(s, heap)
	}
	if sums.failed && err == nil {
		err = core.error_of(core.Typed_Refusal{kind = .No_Memory})
	}
	return err
}

// Whether the format `as` writes flat records.
@(private = "file")
flat :: proc(as: core.As) -> bool {
	services := core.services_of(as)
	return services != nil && services.tokens != nil && (^write.Token_Spelling)(services.tokens).line != nil
}

// A piece's task: its records, taken into a summary of its own that is left at slot `k`.
@(private = "file")
infer_piece :: proc(sums: ^Piece_Sums, it: ^records.Reader, k: int) -> bool {
	heap := runtime.heap_allocator()
	mine := new(Inferred, heap)
	mine.ranges, mine.rows = sums.ranges, sums.rows
	kept := false
	defer if !kept {
		inferred_destroy(mine)
		free(mine, heap)
	}
	bad: core.Error
	for bad == nil {
		// A record's temporary text is released with the record.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		rec, more := records.next(it)
		if !more {
			break
		}
		doc, err := records.build(it, rec, heap)
		if err != nil {
			bad = err
			break
		}
		if infer(mine, core.Node_Ref{&doc, core.ROOT}) != .None {
			bad = core.error_of(core.Typed_Refusal{kind = .No_Memory})
		}
		core.destroy(&doc)
	}
	sync.guard(&sums.lock)
	if bad != nil && k < sums.bad_at {
		sums.bad, sums.bad_at = bad, k
	}
	if it.fault != nil {
		sums.fault_at = min(sums.fault_at, k)
	}
	if k >= len(sums.sums) && resize(&sums.sums, k + 1) != nil {
		sums.failed = true
		return false
	}
	sums.sums[k], kept = mine, true
	return bad == nil
}
