// XML's walk: each grammar state is a procedure that tail-calls the next with `#must_tail`. A state reads the first
// byte of its construct and branches on it. Runs of characters (text.odin), names (name.odin) and the prolog and
// epilog (framing.odin) are read by leaf procedures.
package xml

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"

// `Spec` is the grammar a text follows, a compile-time parameter.
Spec :: enum u8 {
	Xml, // XML 1.0 Fifth Edition, UTF-8, the internal subset read and no external entity
}

// `Options` holds a walk's run-time options. The zero value is the default.
Options :: struct {
	// The deepest element nesting a text may have, 0 for `MAX_DEPTH`. A depth up to `MAX_DEPTH` keeps the frames in
	// `walk_document`'s frame, and a larger one allocates on the default heap.
	max_depth:     u32,
	// A text value that is `true`, `false` or exactly a JSON number reads as a boolean or a number, where every
	// non-empty value is a string by default. An empty one is a null either way. Read by `core.kind`, not by the walk.
	infer:         bool,
	// The rules the text may break. XML has instances of `Unread_Entity` only.
	tolerate:      bit_set[core.Tolerance; u8],
	// The most bytes the entity references of a text may expand to, 0 for the default: 8 MiB, or 100 times the text's
	// length when that is more. The references in content and attribute values and the defaults of attribute-list
	// declarations count, each by its replacement text's size with the references it holds.
	max_expansion: u64,
}

// `Detail` holds XML's detail for a `core.Fault_Kind`, in `core.Fault.detail`. A walk's states choose it where they
// find the fault.
Detail :: enum u8 {
	None,
	Name, // `Bad_Char`: a byte where a name must start
	Space, // `Bad_Char`: no whitespace between a name and the attribute after it, or after a target
	Equals, // `Bad_Char`: a byte where an attribute's `=` must be
	Quote, // `Bad_Char`: a byte that is no quote where an attribute value must start
	Attribute_Lt, // `Bad_Char`: a `<` inside an attribute value
	Duplicate_Attribute, // `Bad_Char`: at the name of an attribute the tag already has
	Empty_Tag, // `Bad_Char`: a `/` in a start tag that no `>` follows
	Mismatched_Tag, // `Bad_Char`: an end tag whose name differs from its start tag's
	Close_Tag, // `Bad_Char`: a byte in an end tag after its name that is no whitespace and no `>`
	Markup, // `Bad_Char`: a `<!` that opens no comment or CDATA section where one may stand
	Comment_Dashes, // `Bad_Char`: `--` inside a comment, not as its close
	Cdata_End, // `Bad_Char`: `]]>` in character data
	Control_Char, // `Bad_Char`: a control byte that is no tab, LF or CR
	Invalid_Utf8, // `Bad_Char`: at the lead byte of an ill-formed UTF-8 sequence
	Non_Char, // `Bad_Char`: U+FFFE or U+FFFF
	Reference, // `Bad_Char`: a `&` that begins no well-formed reference
	Char_Reference, // `Bad_Char`: a character reference to a code point that is no `Char`
	Undeclared_Entity, // `Bad_Char`: a reference to an entity other than the five predefined ones
	Declaration, // `Bad_Char`: a malformed XML declaration
	Reserved_Target, // `Bad_Char`: a processing instruction whose target is `xml`
	Instruction, // `Bad_Char`: a malformed processing instruction
	Encoding, // `Bad_Char`: a text in an encoding other than UTF-8
	Doctype, // `Bad_Char`: a malformed document type declaration
	Prolog, // `Bad_Char`: a byte before the root element that opens no declaration, comment, instruction or element
	Junk_After_Root, // `Bad_Char`: a byte after the root element that is no whitespace, comment or instruction
	Qualified_Name, // `Bad_Char`: a name with a colon that is no prefix and local name, or a prefix of a declaration with one
	Unbound_Prefix, // `Bad_Char`: a prefix that no `xmlns` declaration in scope binds
	Reserved_Prefix, // `Bad_Char`: a declaration of the prefix `xmlns`, of `xml` to another URI, or an element with the prefix `xmlns`
	Reserved_Namespace, // `Bad_Char`: a declaration that binds the `xml` or `xmlns` namespace URI to another prefix or as the default
	Empty_Binding, // `Bad_Char`: a prefix declaration with an empty URI
	Duplicate_Expanded, // `Bad_Char`: an attribute whose namespace and local name the tag already has
	Expansion, // `Too_Wide`: at the reference that takes the entity expansion past `Options.max_expansion`
	Entity_Respelled, // `Bad_Char`: a replacement text whose markup its literal does not spell, so no byte holds it
	Unread_Entity, // `Bad_Char`: a reference to an external entity, or to an undeclared one in a DTD not read whole
	Recursion, // `Bad_Char`: a reference to an entity inside its own replacement text
	Unparsed_Entity, // `Bad_Char`: a reference to an unparsed entity, one with a notation
	External_Entity, // `Bad_Char`: a reference to an external entity in an attribute value
	Entity_Boundary, // `Bad_Char`: a replacement text that is not content, or a reference whose element it does not close
	Element_Declaration, // `Bad_Char`: a malformed element type declaration
	Attribute_Declaration, // `Bad_Char`: a malformed attribute-list declaration
	Entity_Declaration, // `Bad_Char`: a malformed entity declaration
	Notation_Declaration, // `Bad_Char`: a malformed notation declaration
	Subset, // `Bad_Char`: a byte in the internal subset that begins no declaration, reference or comment
	Parameter_Reference, // `Bad_Char`: a parameter-entity reference inside a declaration or an internal entity's value
	Replacement, // `Frozen`: a node whose bytes are an entity's literal or an attribute-list default in the DTD
	Reordered, // `Frozen`: a reorder of an element's children
	Not_Name, // `Frozen`: a rename of `#text`, or to a name that is no XML name or has a colon
	Text_Markup, // `Frozen`: a text run given an element or an array
	Nested_Array, // `Frozen`: an array set as the document, which has one root element
	Comment_Body, // `Frozen`: a comment body that holds `--` or ends in `-`
	No_Place, // `Frozen`: a fact on a node that has no place for it
}

// `RULES` is XML's `core.Rules`, one per `Detail` value, which every fault the walk returns points to.
@(rodata)
RULES := core.Rules {
	"xml",
	{
		{},
		{"name", "Invalid name"},
		{"space", "Missing whitespace"},
		{"equals", "Missing = after attribute name"},
		{"quote", "Attribute value must be quoted"},
		{"attribute_lt", "< in attribute value"},
		{"duplicate_attribute", "Attribute repeated in one tag"},
		{"empty_tag", "/ in a tag without >"},
		{"mismatched_tag", "End tag does not match its start tag"},
		{"close_tag", "Invalid end tag"},
		{"markup", "Invalid markup declaration"},
		{"comment_dashes", "-- inside a comment"},
		{"cdata_end", "]]> in character data"},
		{"control_char", "Control character"},
		{"invalid_utf8", "Invalid UTF-8"},
		{"non_char", "U+FFFE or U+FFFF"},
		{"reference", "Invalid reference"},
		{"char_reference", "Reference to a code point that is not a character"},
		{"undeclared_entity", "Entity is not declared"},
		{"declaration", "Invalid XML declaration"},
		{"reserved_target", "Processing instruction target xml is reserved"},
		{"instruction", "Invalid processing instruction"},
		{"encoding", "Encoding other than UTF-8"},
		{"doctype", "Invalid document type declaration"},
		{"prolog", "Text before the root element"},
		{"junk_after_root", "Text after the root element"},
		{"qualified_name", "Name is no prefix and local name"},
		{"unbound_prefix", "Prefix is not declared"},
		{"reserved_prefix", "Reserved prefix"},
		{"reserved_namespace", "Reserved namespace URI"},
		{"empty_binding", "Prefix bound to an empty URI"},
		{"duplicate_expanded", "Attribute repeated by namespace and local name"},
		{"expansion", "Entity references expand past the expansion budget"},
		{"entity_respelled", "Replacement text spells markup its literal does not"},
		{"unread_entity", "Entity text is not read"},
		{"recursion", "Entity refers to itself"},
		{"unparsed_entity", "Reference to an unparsed entity"},
		{"external_entity", "Reference to an external entity in an attribute value"},
		{"entity_boundary", "Replacement text is not balanced content"},
		{"element_declaration", "Invalid element type declaration"},
		{"attribute_declaration", "Invalid attribute-list declaration"},
		{"entity_declaration", "Invalid entity declaration"},
		{"notation_declaration", "Invalid notation declaration"},
		{"subset", "Invalid internal subset"},
		{"parameter_reference", "Parameter-entity reference inside a declaration"},
		{"replacement", "Node is an entity's replacement text or a declared default"},
		{"reordered", "An element's children keep their order"},
		{"not_name", "An element's name is an XML name with no colon, and `#text` is no element"},
		{"text_markup", "Text holds no element and no array"},
		{"nested_array", "An element holds no array: an array is the elements of one name"},
		{"comment_body", "A comment holds no `--` and does not end in `-`"},
		{"no_place", "This node has no place for the fact"},
	},
}

// `STATE_TIER` is the CPU tier every state is built for, the lowest: `V2` on x86-64, `Base` elsewhere.
@(private)
STATE_TIER :: kernel.Tier(0)

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// `Frame` is an open element. Its name starts one byte past `tag_lo`. `text_lo` is where the text run that has not
// been given yet starts: past the start tag, or past the child that last closed.
@(private)
Frame :: struct {
	tag_lo:  u64,
	text_lo: u64,
	tag_n:   u32,
	name_n:  u16,
	flags:   Frame_Flags,
}

@(private)
Frame_Flag :: enum u8 {
	Object, // the element's `Object` token is given: it has a child element
	Seen, // the run holds a character that is no markup whitespace, so it is text
	Decode, // the run holds a reference, CDATA, a comment, a processing instruction or a CR
	Prev, // a child element or text member ended before this point
}

@(private)
Frame_Flags :: bit_set[Frame_Flag; u16]

#assert(size_of(Frame) == 24)

// The attribute names of a tag that `attr_add` compares without a table.
@(private)
ATTR_SLOTS :: 16

@(private)
Name_Ref :: struct {
	p: [^]u8,
	n: u64,
}

// `Walk` holds the state a walk carries besides its registers. `frames[i]` is the element with `i` open elements
// around it, and `depth` frames are allocated, so no frame is read before it is written.
@(private)
Walk :: struct($H: typeid) {
	base:   [^]u8,
	hooks:  ^H,
	frames: [^]Frame,
	regs:   ^core.Hook_Regs,
	depth:  u64,
	// The deepest nesting the text may have. `depth` is less while the frames hold fewer levels.
	limit:  u64,
	// The number of open elements of the element a `Skip` hid, 0 when no element is hidden. While it is set no token
	// reaches the hook.
	mute:   u64,
	// The names of the tag being read, in `names` up to `ATTR_SLOTS` and then in the `table` out of line.
	names:  [ATTR_SLOTS]Name_Ref,
	table:  [^]Name_Ref,
	nattr:  u64,
	// The namespace declarations in scope: `ns[:ns_len]` in open order, on the default heap and freed with the walk.
	ns:     [^]Ns_Entry,
	ns_len: u32,
	ns_cap: u32,
	// Whether the tag being read has a name with a colon or a declaration, so its names are judged at its end.
	tag_ns: bool,
	tier:   kernel.Tier,
	// Whether `frames` is this walk's own, grown on the default heap by `deepen`, which the walk's end frees.
	owned:  bool,
	// Whether the DTD declares attribute defaults, so each tag is checked for them at its end.
	tag_dtd: bool,
	// The DTD the text declares, nil for none, and the run `st_halt` acts on.
	dtd:    ^Dtd,
	halt:   Run,
	opts:   Options,
}

// Checks that `src` holds exactly one XML document in UTF-8, with no hook and after one leading BOM. Returns the fault,
// or nil. A constant `spec` links the walk of that spec alone, and a `spec` chosen at run time is `core.validate` with
// `as(spec, opts)`. The same holds for the other entry points.
validate :: proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> core.Error {
	return core.error_of(validate_spec(src, spec, opts))
}

// Reads `src` as one document from `lo` through the hook, as `validate` checks it. A BOM is passed over only at the
// text's first byte. The tokens come in text order. The document is an `Object` of one member, the root element: a
// `Key` of its name, then its `Attribute` facts, then its value. An element with no child element has a `Plain` value
// that spans its content, empty for none. An element with a child element is an `Object` that spans its start tag,
// then a `Key` of `#text` with no bytes of its own and a `Plain` for each run of text between its children, and its
// child elements as members, then an `End` that spans the end tag. A run is text when it holds a character that is no
// markup whitespace, and `SPELLING_DECODE` says its bytes need decoding. Comments and processing instructions come
// as facts before the token they precede, by the comment position rule, and the `Doctype` before the document's
// `Object`. A hook that stops the walk ends the read with no fault. Returns one past the last byte read and the fault,
// or nil. `regs` is passed to the first token and holds what the hook returned last, and a nil `regs` starts from zero
// registers and keeps none. With a `cursor`, a stop saves where the walk stood there for `walk_resume`.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault)) {
	if cursor != nil {
		return walk_holding(src, lo, opts, h, regs, on, cursor)
	}
	zero: core.Hook_Regs
	r := regs
	if r == nil {
		r = &zero
	}
	hi, fault, _ = core.result_of(walk_document(src, lo, opts, h, r, on, nil), &RULES)
	return
}

// `walk` from the text's start that also returns the sealed DTD the text declares, empty for none, on the default heap
// for the caller to free.
@(private)
walk_keeping :: proc "contextless" (src: []u8, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault), state: []u8) {
	hi, fault, _ = core.result_of(walk_document(src, 0, opts, h, regs, on, &state), &RULES)
	return
}

// The walk's verdict on `src` for `spec`, with no hook.
@(private)
validate_spec :: proc "contextless" (src: []u8, spec: Spec, opts: Options) -> Maybe(core.Fault) {
	h: core.No_Hooks
	regs: core.Hook_Regs
	_, fault, _ := core.result_of(walk_document(src, 0, opts, &h, &regs, core.no_hook, nil), &RULES)
	return fault
}

// Reads the document that starts at `lo`. Keeps the frames in this frame, which `deepen` grows on the default heap
// for a text that nests past it, freed before returning. The DTD is freed too, or its sealed block handed to `kept`.
@(private)
walk_document :: #force_inline proc "contextless" (src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), kept: ^[]u8) -> u64 {
	// `= ---` leaves the array unwritten, where a struct would be zeroed. Every frame is written before it is read.
	frames: [core.MAX_DEPTH]Frame = ---
	limit := u64(opts.max_depth) if opts.max_depth != 0 else core.MAX_DEPTH
	w := Walk(H) {
		base   = raw_data(src),
		hooks  = h,
		frames = raw_data(frames[:]),
		regs   = regs,
		depth  = min(limit, core.MAX_DEPTH),
		limit  = limit,
		tier   = kernel.tier(),
		opts   = opts,
	}
	r := prolog(&w, src, min(lo, u64(len(src))), regs.a, regs.b, regs.c, on)
	if w.dtd != nil {
		r = dtd_end(&w, r, kept)
	}
	if w.owned {
		runtime.heap_free(w.frames)
	}
	if w.table != nil {
		runtime.heap_free(w.table)
	}
	if w.ns != nil {
		for entry in w.ns[:w.ns_len] {
			if entry.owned {
				runtime.heap_free(entry.uri.p)
			}
		}
		runtime.heap_free(w.ns)
	}
	return r
}

// Passes the token to the hook. `skip_at` is the open count of the element a `Skip` on this token hides, 0 for a token
// that cannot be skipped.
@(private)
Emitted :: enum u8 {
	Next,
	Stop,
	Wide,
}

@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, kind: core.Kind, role: core.Role, lo: u64, n: int, spelling: u16 = 0, skip_at: u64 = 0) -> Emitted {
	when H == core.No_Hooks {
		return .Next
	} else {
		if w.mute != 0 {
			return .Next
		}
		if u64(n) > u64(max(u32)) {
			return .Wide
		}
		when intrinsics.type_is_specialization_of(H, core.Holding) {
			w.hooks.skip_at = skip_at
		}
		a: core.Action
		hs^, a = on(w.hooks, hs^, core.Token{lo, u32(n), kind, role, spelling})
		if a == .Skip && skip_at != 0 {
			w.mute = skip_at
		}
		return .Stop if a == .Stop else .Next
	}
}

// The result for the token that `emit` refused: a stop of the walk, or a token wider than `Token.n` holds.
@(private, cold)
refused :: #force_no_inline proc "contextless" (w: ^Walk($H), hs: core.Hook_Regs, e: Emitted, p: [^]u8) -> u64 {
	if e == .Wide {
		return fault(w, hs, p, .Too_Wide)
	}
	return stopped(w, hs, p)
}

@(private)
at :: #force_inline proc "contextless" (w: ^Walk($H), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, w.base))
}

@(private)
fault :: #force_inline proc "contextless" (w: ^Walk($H), hs: core.Hook_Regs, p: [^]u8, kind: core.Fault_Kind, detail := Detail.None) -> u64 {
	w.regs^ = hs
	return core.fault_at(at(w, p), kind, u8(detail))
}

// Returns the result for a hook that stopped the walk at the token ending at `p`, with `core.STOPPED` in the detail.
@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($H), hs: core.Hook_Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return core.fault_at(at(w, p), .None, core.STOPPED)
}

// The fault for a run that `run` or `name_end` refused.
@(private, cold)
run_fault :: #force_no_inline proc "contextless" (w: ^Walk($H), hs: core.Hook_Regs, r: Run) -> u64 {
	return fault(w, hs, r.q, r.kind, r.detail)
}

// Fault for a name that `name_end` refused at `q` where the name was due.
@(private, cold)
name_fault :: #force_no_inline proc "contextless" (w: ^Walk($H), hs: core.Hook_Regs, q, end: [^]u8, f: Name_Fault, detail: Detail) -> u64 {
	switch f {
	case .Truncated:
		return fault(w, hs, end, .Truncated)
	case .Bad_Utf8:
		return fault(w, hs, q, .Bad_Char, .Invalid_Utf8)
	case .Not_Name, .None:
	}
	return fault(w, hs, q, .Bad_Char, detail)
}

// The fault of an element opened past the depth the walk checks, `.None` once the check is raised past it: the frames
// grow to twice the levels, up to the limit.
@(private, cold)
deepen :: #force_no_inline proc "contextless" (w: ^Walk($H)) -> core.Fault_Kind {
	if w.depth >= w.limit {
		return .Too_Deep
	}
	want := min(w.limit, max(2 * w.depth, w.depth + 1))
	frames := runtime.heap_resize(w.frames, int(want) * size_of(Frame)) if w.owned else runtime.heap_alloc(int(want) * size_of(Frame), false)
	if frames == nil {
		return .No_Memory
	}
	if !w.owned {
		intrinsics.mem_copy_non_overlapping(frames, w.frames, int(w.depth) * size_of(Frame))
	}
	w.frames, w.owned, w.depth = ([^]Frame)(frames), true, want
	return .None
}

@(private)
is_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

// Returns the first byte at or past `p` that is no space, tab, CR or LF, or `end`. Reads up to four bytes one at a
// time, then 64-byte blocks, then the remaining bytes one at a time.
@(private)
skip_ws :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for _ in 0 ..< 4 {
		if q >= end || !is_ws(q[0]) {
			return q
		}
		q = q[1:]
	}
	for intrinsics.ptr_sub(end, q) >= 64 {
		b := kernel.load(q)
		ws := kernel.pack(kernel.either(kernel.either(kernel.eq(b, ' '), kernel.eq(b, '\n')), kernel.either(kernel.eq(b, '\t'), kernel.eq(b, '\r'))))
		if ws != max(u64) {
			return q[intrinsics.count_trailing_zeros(~ws):]
		}
		q = q[64:]
	}
	for q < end && is_ws(q[0]) {
		q = q[1:]
	}
	return q
}

// Whether `[p, q)` holds a CR.
@(private)
has_cr :: #force_inline proc "contextless" (p, q: [^]u8) -> bool #no_bounds_check {
	for x := p; x < q; x = x[1:] {
		if x[0] == '\r' {
			return true
		}
	}
	return false
}

// Opens the container of the element whose frame is `f`, with `e` open elements, when its first child starts at `child`:
// gives the `Object` and the text before the child as a `#text` member. Returns whether the walk is over, with its result.
@(private)
open_content :: #force_inline proc "contextless" (w: ^Walk($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, f: ^Frame, e: u64, child: [^]u8) -> (result: u64, done: bool) {
	if .Object not_in f.flags {
		f.flags += {.Object}
		if r := emit(w, on, hs, .Object, .Value, f.tag_lo, int(f.tag_n), 0, e); r != .Next {
			return refused(w, hs^, r, child), true
		}
	}
	return text_member(w, on, hs, f, child)
}

// Gives the text run of frame `f` that ends at `end_of_run` as a `#text` member when it is text, and starts the next run.
@(private)
text_member :: #force_inline proc "contextless" (w: ^Walk($H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, f: ^Frame, end_of_run: [^]u8) -> (result: u64, done: bool) {
	if .Seen in f.flags {
		lo := f.text_lo
		n := int(at(w, end_of_run) - lo)
		if r := emit(w, on, hs, .String, .Key, lo, 0, core.SPELLING_SYNTHETIC); r != .Next {
			return refused(w, hs^, r, end_of_run), true
		}
		if r := emit(w, on, hs, .Plain, .Value, lo, n, core.SPELLING_DECODE if .Decode in f.flags else 0); r != .Next {
			return refused(w, hs^, r, end_of_run), true
		}
	}
	f.flags -= {.Seen, .Decode}
	f.flags += {.Prev}
	return 0, false
}

// `p` is at a `<` that starts an element, in the content of the element with `d` open elements, or at the document
// level when `d` is 0. Reads the start tag: the name, then the attributes, each given as a fact, then its `>` or
// `/>`. Gives the `Key` first.
@(private, enable_target_feature = STATE_FEATURES)
st_start :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, nf, colon := name_end_colon(p[1:], end)
	if nf != .None {
		return name_fault(w, hs, q, end, nf, .Name)
	}
	name_n := intrinsics.ptr_sub(q, p[1:])
	if name_n > int(max(u16)) {
		return fault(w, hs, p, .Too_Wide)
	}
	if d >= w.depth {
		if kind := deepen(w); kind != .None {
			return fault(w, hs, p, kind)
		}
	}
	if d > 0 {
		if r, done := open_content(w, on, &hs, &w.frames[d - 1], d, p); done {
			return r
		}
	}
	w.frames[d] = Frame{tag_lo = at(w, p), name_n = u16(name_n)}
	w.nattr = 0
	w.tag_ns = colon
	if r := emit(w, on, &hs, .String, .Key, at(w, p) + 1, name_n, 0, d + 1); r != .Next {
		return refused(w, hs, r, q)
	}
	return #must_tail st_attributes(q, end, d + 1, w, hs.a, hs.b, hs.c, on)
}

// `p` is inside the start tag of the element with `e` open elements, after its name or an attribute. Reads the
// attributes, giving each as a `Role.Attribute` fact, to the tag's `>` or `/>`.
@(private, enable_target_feature = STATE_FEATURES)
st_attributes :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q := p
	for {
		gap := q
		q = skip_ws(q, end)
		if q >= end {
			return fault(w, hs, end, .Truncated)
		}
		switch q[0] {
		case '>':
			return #must_tail st_open_done(q, end, e, w, hs.a, hs.b, hs.c, on)
		case '/':
			if intrinsics.ptr_sub(end, q) < 2 {
				return fault(w, hs, end, .Truncated)
			}
			if q[1] != '>' {
				return fault(w, hs, q, .Bad_Char, .Empty_Tag)
			}
			return #must_tail st_empty_done(q, end, e, w, hs.a, hs.b, hs.c, on)
		}
		if q == gap {
			return fault(w, hs, q, .Bad_Char, .Space)
		}
		name_end_at, nf, colon := name_end_colon(q, end)
		if nf != .None {
			return name_fault(w, hs, name_end_at, end, nf, .Name)
		}
		name_n := intrinsics.ptr_sub(name_end_at, q)
		if name_n > int(max(u16)) {
			return fault(w, hs, q, .Too_Wide)
		}
		eq := skip_ws(name_end_at, end)
		if eq >= end {
			return fault(w, hs, end, .Truncated)
		}
		if eq[0] != '=' {
			return fault(w, hs, eq, .Bad_Char, .Equals)
		}
		v := skip_ws(eq[1:], end)
		if v >= end {
			return fault(w, hs, end, .Truncated)
		}
		r: Run
		switch v[0] {
		case '"':
			r = run(w, v[1:], end, .Attr, '"')
		case '\'':
			r = run(w, v[1:], end, .Attr, '\'')
		case:
			return fault(w, hs, v, .Bad_Char, .Quote)
		}
		if r.kind != .None {
			return run_fault(w, hs, r)
		}
		if attr_repeats(w, q, u64(name_n)) {
			return fault(w, hs, q, .Bad_Char, .Duplicate_Attribute)
		}
		if colon || q[0] == 'x' {
			if kind, rule := attribute_scope(w, q, name_n, v[1:], r.q, e, colon); kind != .None {
				return fault(w, hs, q, kind, rule)
			}
		}
		value_end := r.q[1:]
		if x := emit(w, on, &hs, .Plain, .Attribute, at(w, q), intrinsics.ptr_sub(value_end, q), attribute_spelling(intrinsics.ptr_sub(v[1:], q))); x != .Next {
			return refused(w, hs, x, value_end)
		}
		q = value_end
	}
}

// Adds the attribute name at `name` to the tag's names. Returns whether the tag already has it.
@(private)
attr_repeats :: #force_inline proc "contextless" (w: ^Walk($H), name: [^]u8, n: u64) -> bool #no_bounds_check {
	i := w.nattr
	if i < ATTR_SLOTS {
		for j in 0 ..< i {
			if w.names[j].n == n && string(name[:n]) == string(w.names[j].p[:n]) {
				return true
			}
		}
		w.names[i] = Name_Ref{name, n}
		w.nattr += 1
		return false
	}
	return attr_repeats_table(w, name, n)
}

// `attr_repeats` for a tag with more than `ATTR_SLOTS` attributes: the names are in an open-addressing table that
// doubles when half full. A table that cannot grow stops checking the tag's later attributes.
@(private, cold)
attr_repeats_table :: #force_no_inline proc "contextless" (w: ^Walk($H), name: [^]u8, n: u64) -> bool #no_bounds_check {
	if w.nattr == ATTR_SLOTS {
		w.table = ([^]Name_Ref)(runtime.heap_alloc(64 * size_of(Name_Ref), true))
		if w.table == nil {
			return false
		}
		for j in 0 ..< ATTR_SLOTS {
			table_put(w.table, 64, w.names[j].p, w.names[j].n)
		}
	}
	cap := table_cap(w.nattr)
	if w.nattr * 2 >= cap {
		bigger := ([^]Name_Ref)(runtime.heap_alloc(int(cap * 2) * size_of(Name_Ref), true))
		if bigger == nil {
			return false
		}
		for j in 0 ..< cap {
			if w.table[j].p != nil {
				table_put(bigger, cap * 2, w.table[j].p, w.table[j].n)
			}
		}
		runtime.heap_free(w.table)
		w.table = bigger
		cap *= 2
	}
	w.nattr += 1
	return !table_put(w.table, cap, name, n)
}

// The capacity of the table that holds `count` names, a power of two from 64.
@(private)
table_cap :: #force_inline proc "contextless" (count: u64) -> u64 {
	cap := u64(64)
	for cap < count * 2 {
		cap *= 2
	}
	return cap
}

// Puts a name in `table` of capacity `cap`. Returns false when it is already there.
@(private)
table_put :: proc "contextless" (table: [^]Name_Ref, cap: u64, name: [^]u8, n: u64) -> bool #no_bounds_check {
	h := u64(14695981039346656037)
	for b in name[:n] {
		h = (h ~ u64(b)) * 1099511628211
	}
	for i := h & (cap - 1); ; i = (i + 1) & (cap - 1) {
		if table[i].p == nil {
			table[i] = Name_Ref{name, n}
			return true
		}
		if table[i].n == n && string(table[i].p[:n]) == string(name[:n]) {
			return false
		}
	}
}

// `p` is at the `>` that ends the start tag of the element with `e` open elements. Its content follows.
@(private, enable_target_feature = STATE_FEATURES)
st_open_done :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	f := &w.frames[e - 1]
	n := intrinsics.ptr_sub(p[1:], w.base[f.tag_lo:])
	if n > int(max(u32)) {
		return fault(w, {s0, s1, s2}, p, .Too_Wide)
	}
	f.tag_n = u32(n)
	f.text_lo = at(w, p) + 1
	if w.tag_dtd {
		return #must_tail st_defaults(p, end, e, w, s0, s1, s2, on)
	}
	if w.nattr > ATTR_SLOTS {
		runtime.heap_free(w.table)
		w.table = nil
	}
	if w.tag_ns {
		if kind, d := tag_names(w, w.base[f.tag_lo:], p); kind != .None {
			return fault(w, {s0, s1, s2}, w.base[f.tag_lo:], kind, d)
		}
	}
	return #must_tail st_content(p[1:], end, e, w, s0, s1, s2, on)
}

// Pops the declarations of the element with `e` open elements, freeing the URIs they own, and goes on as `st_closed`.
// A call in `st_closed` itself would cost every close.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_unbind :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	for w.ns_len > 0 && w.ns[w.ns_len - 1].depth == e {
		w.ns_len -= 1
		if w.ns[w.ns_len].owned {
			runtime.heap_free(w.ns[w.ns_len].uri.p)
		}
	}
	return #must_tail st_closed(p, end, e, w, s0, s1, s2, on)
}

// `p` is at the `/` of the `/>` that ends the start tag of the element with `e` open elements. The element is empty,
// so its value is a null.
@(private, enable_target_feature = STATE_FEATURES)
st_empty_done :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	if w.tag_dtd {
		return #must_tail st_defaults(p, end, e, w, s0, s1, s2, on)
	}
	hs := core.Hook_Regs{s0, s1, s2}
	if w.nattr > ATTR_SLOTS {
		runtime.heap_free(w.table)
		w.table = nil
	}
	if w.tag_ns {
		if kind, d := tag_names(w, w.base[w.frames[e - 1].tag_lo:], p); kind != .None {
			return fault(w, hs, w.base[w.frames[e - 1].tag_lo:], kind, d)
		}
	}
	if x := emit(w, on, &hs, .Plain, .Value, at(w, p), 0); x != .Next {
		return refused(w, hs, x, p[2:])
	}
	return #must_tail st_closed(p[2:], end, e, w, hs.a, hs.b, hs.c, on)
}

// An element with `e` open elements, itself included, ended with its last byte just before `p`. Hands the walk to the
// content of its parent, or to the epilog after the root.
@(private, enable_target_feature = STATE_FEATURES)
st_closed :: #force_no_inline proc "contextless" (p, end: [^]u8, e: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	if w.mute == e {
		w.mute = 0
	}
	when intrinsics.type_is_specialization_of(H, core.Holding) {
		if w.hooks.held != nil {
			core.hold(w.hooks, core.Held_Token{at = e, close = true})
		}
	}
	for w.ns_len > 0 && w.ns[w.ns_len - 1].depth == e {
		if w.ns[w.ns_len - 1].owned {
			return #must_tail st_unbind(p, end, e, w, s0, s1, s2, on)
		}
		w.ns_len -= 1
	}
	if e == 1 {
		return #must_tail st_epilog(p, end, e, w, s0, s1, s2, on)
	}
	f := &w.frames[e - 2]
	f.text_lo = at(w, p)
	f.flags -= {.Seen, .Decode}
	f.flags += {.Prev}
	return #must_tail st_content(p, end, e - 1, w, s0, s1, s2, on)
}

// `p` is in the content of the element with `d` open elements, at the start of a character run or a markup construct.
// Reads whitespace and then character data up to the next `<`, then branches on what the `<` opens.
@(private, enable_target_feature = STATE_FEATURES)
st_content :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	q := skip_ws(p, end)
	if q >= end {
		w.halt = Run{q = end, decode = q > p && has_cr(p, q), kind = .Truncated}
		return #must_tail st_halt(q, end, d, w, s0, s1, s2, on)
	}
	if q[0] != '<' {
		f := &w.frames[d - 1]
		if q > p && has_cr(p, q) {
			f.flags += {.Decode}
		}
		r := run(w, q, end, .Text, 0)
		if r.kind != .None {
			w.halt = r
			return #must_tail st_halt(q, end, d, w, s0, s1, s2, on)
		}
		f.flags += {.Seen}
		if r.decode {
			f.flags += {.Decode}
		}
		q = r.q
	}
	if intrinsics.ptr_sub(end, q) < 2 {
		return fault(w, {s0, s1, s2}, end, .Truncated)
	}
	switch q[1] {
	case '/':
		return #must_tail st_end(q, end, d, w, s0, s1, s2, on)
	case '!':
		return #must_tail st_bang(q, end, d, w, s0, s1, s2, on)
	case '?':
		return #must_tail st_misc(q, end, d, w, s0, s1, s2, on)
	}
	return #must_tail st_start(q, end, d, w, s0, s1, s2, on)
}

// `p` is at `<!` in the content of the element with `d` open elements: a comment or a CDATA section.
@(private, enable_target_feature = STATE_FEATURES)
st_bang :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	room := intrinsics.ptr_sub(end, p)
	if room >= 4 && p[2] == '-' && p[3] == '-' {
		return #must_tail st_misc(p, end, d, w, s0, s1, s2, on)
	}
	CDATA :: "<![CDATA["
	if !prefix_of(p, min(room, len(CDATA)), CDATA) {
		return fault(w, {s0, s1, s2}, p, .Bad_Char, .Markup)
	}
	if room < len(CDATA) {
		return fault(w, {s0, s1, s2}, end, .Truncated)
	}
	r := run(w, p[len(CDATA):], end, .Cdata, 0)
	if r.kind != .None {
		return run_fault(w, {s0, s1, s2}, r)
	}
	f := &w.frames[d - 1]
	f.flags += {.Seen, .Decode}
	return #must_tail st_content(r.q[3:], end, d, w, s0, s1, s2, on)
}

// `p` is at a comment or a processing instruction in the content of the element with `d` open elements. Reads the
// run of comments, instructions and whitespace up to the next byte, then gives them: those on the line where the
// element's last child ended are inline comments, and the rest are comments of what follows, or foot comments when
// the element's end tag follows a child.
@(private, enable_target_feature = STATE_FEATURES)
st_misc :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, r := misc_run(w, p, end)
	if r.kind != .None {
		return run_fault(w, hs, r)
	}
	f := &w.frames[d - 1]
	f.flags += {.Decode}
	when H != core.No_Hooks {
		foot := .Object in f.flags && intrinsics.ptr_sub(end, q) >= 2 && q[0] == '<' && q[1] == '/'
		inline := .Prev in f.flags && .Seen not_in f.flags
		// The whitespace before the run, which `st_content` has passed, says whether the first comment is on the line
		// where the element before it ended.
		lead := p
		for lead > w.base[f.text_lo:] && is_ws(lead[-1]) {
			lead = lead[-1:]
		}
		if x, at_ := give_misc(w, on, &hs, lead, q, end, inline, .Comment_Foot if foot else .Comment); x != .Next {
			return refused(w, hs, x, at_)
		}
	}
	return #must_tail st_content(q, end, d, w, hs.a, hs.b, hs.c, on)
}

// `p` is at the `</` of an end tag in the content of the element with `d` open elements. Checks that the name is the
// element's, then closes it: gives its text as the value, or the text before its end as a `#text` member and the
// `End`.
@(private, enable_target_feature = STATE_FEATURES)
st_end :: #force_no_inline proc "contextless" (p, end: [^]u8, d: u64, w: ^Walk($H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	f := &w.frames[d - 1]
	n := int(f.name_n)
	name := w.base[f.tag_lo + 1:]
	room := intrinsics.ptr_sub(end, p[2:])
	if room < n {
		if string(p[2:][:room]) != string(name[:room]) {
			return fault(w, hs, p[2:], .Bad_Char, .Mismatched_Tag)
		}
		return fault(w, hs, end, .Truncated)
	}
	if string(p[2:][:n]) != string(name[:n]) {
		return fault(w, hs, p[2:], .Bad_Char, .Mismatched_Tag)
	}
	q := p[2 + n:]
	if q < end && NAME_BYTE[q[0]] != .No {
		return fault(w, hs, q, .Bad_Char, .Mismatched_Tag)
	}
	q = skip_ws(q, end)
	if q >= end {
		return fault(w, hs, end, .Truncated)
	}
	if q[0] != '>' {
		return fault(w, hs, q, .Bad_Char, .Close_Tag)
	}
	after := q[1:]
	if .Object in f.flags {
		if r, done := text_member(w, on, &hs, f, p); done {
			return r
		}
		if x := emit(w, on, &hs, .End, .Value, at(w, p), intrinsics.ptr_sub(after, p)); x != .Next {
			return refused(w, hs, x, after)
		}
	} else {
		lo := f.text_lo
		// A run of white space alone is no text run, so no scan judged its line ends.
		decode := .Decode in f.flags || .Seen not_in f.flags && has_cr(w.base[lo:], p)
		spelling := core.SPELLING_DECODE if decode else 0
		if x := emit(w, on, &hs, .Plain, .Value, lo, int(at(w, p) - lo), spelling); x != .Next {
			return refused(w, hs, x, p)
		}
	}
	return #must_tail st_closed(after, end, d, w, hs.a, hs.b, hs.c, on)
}
