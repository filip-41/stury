package xml

import "base:intrinsics"
import "base:runtime"
import core "../core"

// The DTD's tables: the entities and the attribute-list declarations of the internal subset, a name table over both,
// and the bytes they name. The walk builds them on the default heap while it reads the subset, then seals them into one
// block, `Dtd_Head` and then the entities, the declarations, the name slots and the bytes, which it reads to the text's
// end and a document keeps in `Token_View.state`.

@(private)
NO_DECL :: max(u32)

@(private)
Dtd_Flag :: enum u32 {
	Complete, // no external subset and no parameter-entity reference: a reference to an undeclared entity is not well-formed
	Standalone, // the XML declaration says `standalone="yes"`
	Html, // the public identifier is one the HTML standard lists, so its named references read
	Defaults, // an attribute-list declaration gives a default
	In_Place, // a reference was walked over its literal, so some nodes lie in the internal subset
	Stopped, // a parameter entity that was not read was referenced: later entity and attribute-list declarations are not processed
}

@(private)
Dtd_Flags :: bit_set[Dtd_Flag; u32]

@(private)
Dtd_Head :: struct {
	entities:  u32,
	attrs:     u32,
	slots:     u32,
	flags:     Dtd_Flags,
	bytes:     u64,
	// The DOCTYPE's internal subset in `src`, where every node of an entity walked over its literal lies.
	subset_lo: u64,
	subset_hi: u64,
}

#assert(size_of(Dtd_Head) == 40)

@(private)
Entity_Flag :: enum u16 {
	Parameter, // `%name;`
	External, // a `SYSTEM` or `PUBLIC` entity, never read
	Unparsed, // an external entity with an `NDATA` notation
	Stored, // the replacement text is in the bytes, since it differs from the literal
	Lit_Stored, // the literal is in the bytes, from a parameter entity's stored replacement text
	Measured, // `size` and the flags from `Markup` on are set
	Measuring, // being measured: a reference to it now is a recursion
	Markup, // the replacement text, with the entities it refers to, holds a `<`
	Element, // the replacement text, with the entities it refers to, holds a start tag
	Respelled, // the replacement text holds markup the literal does not spell, so it cannot be walked over the literal
	Cdata_End, // the replacement text holds `]]>`
	External_Ref, // the replacement text refers to an external entity
	Unparsed_Ref, // the replacement text refers to an unparsed entity
	Undeclared_Ref, // the replacement text refers to an entity no declaration names
}

@(private)
Entity_Flags :: bit_set[Entity_Flag; u16]

// An entity's replacement text is `text_n` bytes at `text_lo`, in the bytes when `.Stored` and in `src` otherwise, and
// its literal is `lit_n` bytes at `lit_lo`, past the opening quote. `size` bounds the bytes its expansion decodes to,
// saturating.
@(private)
Entity :: struct {
	text_lo: u64,
	lit_lo:  u64,
	size:    u64,
	name_lo: u32,
	text_n:  u32,
	lit_n:   u32,
	name_n:  u16,
	flags:   Entity_Flags,
}

#assert(size_of(Entity) == 40)

// An attribute an attribute-list declaration names. A default's fact spans `src` from the attribute's name through the
// default's closing quote, as an attribute in a tag spans its name through its value, and `lead` is the fact's lead,
// the bytes before the default's value, saturated at `LEAD_MAX`. `size` bounds the bytes the default's value decodes
// to.
@(private)
Attr_Decl :: struct {
	fact_lo:    u64,
	size:       u64,
	element_lo: u32,
	name_lo:    u32,
	fact_n:     u32,
	next:       u32, // the element's next declaration, `NO_DECL` for none
	element_n:  u16,
	name_n:     u16,
	tokenized:  bool, // a type other than `CDATA`, whose value collapses its spaces
	defaulted:  bool,
	qualified:  bool, // the name has a prefix, so a tag it is a default of has its names judged again
	lead:       u8,
}

#assert(size_of(Attr_Decl) == 40)

// The kinds of names the slots hold, in the slot's top two bits.
@(private)
Slot_Kind :: enum u32 {
	General,
	Parameter,
	Element, // the first attribute-list declaration of an element
}

@(private)
Dtd_View :: struct {
	head:     ^Dtd_Head,
	entities: []Entity,
	attrs:    []Attr_Decl,
	slots:    []u32,
	bytes:    []u8,
}

// A reference the walk entered: it reads the literal of `entity` and resumes at `resume`, before `end`, when the
// literal ends. `at` is the reference's `&`. `depth` and `tag_lo` are the open count and the start tag of the element
// around the reference, which the literal must close as it found.
@(private)
Entity_Frame :: struct {
	resume: [^]u8,
	end:    [^]u8,
	at:     [^]u8,
	depth:  u64,
	tag_lo: u64,
	entity: u32,
}

// The DTD a walk reads by. The tables grow in the builder's arrays while the internal subset is read and are sealed into
// `block` at its end. `view` reads either.
@(private)
Dtd :: struct {
	using view: Dtd_View,
	src:        []u8,
	block:      [^]u8,
	block_n:    int,
	built:      Dtd_Head,
	ents:       [^]Entity,
	ent_cap:    u32,
	atts:       [^]Attr_Decl,
	att_cap:    u32,
	slot_mem:   [^]u32,
	arena:      [^]u8,
	arena_n:    u64,
	arena_cap:  u64,
	// The expansion the references at the document's level have added, and the most it may reach.
	total:      u64,
	limit:      u64,
	tolerate:   bool, // `core.Tolerance.Unread_Entity`
	stack:      [^]Entity_Frame,
	depth:      u32,
	stack_cap:  u32,
}

// Makes the DTD of a walk over `src`, or nil when memory runs out.
@(private)
dtd_make :: proc "contextless" (src: []u8, opts: Options) -> ^Dtd {
	d := (^Dtd)(runtime.heap_alloc(size_of(Dtd), true))
	if d == nil {
		return nil
	}
	d.src = src
	d.tolerate = .Unread_Entity in opts.tolerate
	d.limit = opts.max_expansion
	if d.limit == 0 {
		amplified, over := intrinsics.overflow_mul(u64(len(src)), 100)
		d.limit = max(8 << 20, max(u64) if over else amplified)
	}
	d.head = &d.built
	return d
}

@(private)
dtd_free :: proc "contextless" (d: ^Dtd) {
	if d == nil {
		return
	}
	for p in ([]rawptr{d.block, d.ents, d.atts, d.slot_mem, d.arena, d.stack}) {
		if p != nil {
			runtime.heap_free(p)
		}
	}
	runtime.heap_free(d)
}

// Points the view at the builder's arrays.
@(private)
dtd_refresh :: proc "contextless" (d: ^Dtd) {
	d.entities = d.ents[:d.built.entities]
	d.attrs = d.atts[:d.built.attrs]
	d.slots = d.slot_mem[:d.built.slots]
	d.bytes = d.arena[:d.arena_n]
}

// Returns the view of a sealed block, empty for no block.
@(private)
dtd_view :: proc "contextless" (block: []u8) -> (v: Dtd_View) {
	if len(block) < size_of(Dtd_Head) {
		return
	}
	p := raw_data(block)
	v.head = (^Dtd_Head)(p)
	at := size_of(Dtd_Head)
	v.entities = ([^]Entity)(p[at:])[:v.head.entities]
	at += int(v.head.entities) * size_of(Entity)
	v.attrs = ([^]Attr_Decl)(p[at:])[:v.head.attrs]
	at += int(v.head.attrs) * size_of(Attr_Decl)
	v.slots = ([^]u32)(p[at:])[:v.head.slots]
	at += int(v.head.slots) * size_of(u32)
	v.bytes = p[at:][:v.head.bytes]
	return
}

// Copies the tables into one block and frees the builder's arrays. Returns false when memory runs out.
@(private)
dtd_seal :: proc "contextless" (d: ^Dtd) -> bool {
	h := d.built
	h.bytes = d.arena_n
	n := size_of(Dtd_Head) + int(h.entities) * size_of(Entity) + int(h.attrs) * size_of(Attr_Decl) + int(h.slots) * size_of(u32) + int(h.bytes)
	// The slots end at a multiple of 4 and the bytes take any alignment, so the block's tail needs no padding.
	block := ([^]u8)(runtime.heap_alloc(n, false))
	if block == nil {
		return false
	}
	(^Dtd_Head)(block)^ = h
	v := dtd_view(block[:n])
	intrinsics.mem_copy_non_overlapping(raw_data(v.entities), d.ents, int(h.entities) * size_of(Entity))
	intrinsics.mem_copy_non_overlapping(raw_data(v.attrs), d.atts, int(h.attrs) * size_of(Attr_Decl))
	intrinsics.mem_copy_non_overlapping(raw_data(v.slots), d.slot_mem, int(h.slots) * size_of(u32))
	intrinsics.mem_copy_non_overlapping(raw_data(v.bytes), d.arena, int(h.bytes))
	for p in ([]rawptr{d.ents, d.atts, d.slot_mem, d.arena}) {
		if p != nil {
			runtime.heap_free(p)
		}
	}
	d.ents, d.atts, d.slot_mem, d.arena = nil, nil, nil, nil
	d.block, d.block_n = block, n
	d.view = v
	return true
}

@(private)
name_hash :: #force_inline proc "contextless" (kind: Slot_Kind, name: []u8) -> u32 {
	h := u32(2166136261) ~ u32(kind)
	for b in name {
		h = (h ~ u32(b)) * 16777619
	}
	return h
}

// The name a slot's record has.
@(private)
slot_name :: #force_inline proc "contextless" (v: ^Dtd_View, kind: Slot_Kind, index: u32) -> []u8 #no_bounds_check {
	if kind == .Element {
		a := &v.attrs[index]
		return v.bytes[a.element_lo:][:a.element_n]
	}
	e := &v.entities[index]
	return v.bytes[e.name_lo:][:e.name_n]
}

// Returns the index of the entity of `kind` named `name`, or of the first attribute-list declaration of the element
// `name`, or `NO_DECL`.
@(private)
dtd_find :: proc "contextless" (v: ^Dtd_View, kind: Slot_Kind, name: []u8) -> u32 #no_bounds_check {
	if len(v.slots) == 0 {
		return NO_DECL
	}
	mask := u32(len(v.slots) - 1)
	for i := name_hash(kind, name) & mask; ; i = (i + 1) & mask {
		s := v.slots[i]
		if s == 0 {
			return NO_DECL
		}
		if Slot_Kind(s >> 30) == kind {
			index := s & (1 << 30 - 1) - 1
			if string(slot_name(v, kind, index)) == string(name) {
				return index
			}
		}
	}
}

// Adds the record `index` of `kind` to the slots, which double when half full. Returns false when memory runs out.
@(private)
dtd_put :: proc "contextless" (d: ^Dtd, kind: Slot_Kind, index: u32) -> bool #no_bounds_check {
	used := d.built.entities + d.built.attrs
	if 2 * used >= d.built.slots {
		cap := max(64, 2 * d.built.slots)
		fresh := ([^]u32)(runtime.heap_alloc(int(cap) * size_of(u32), true))
		if fresh == nil {
			return false
		}
		old := d.slot_mem[:d.built.slots]
		for s in old {
			if s != 0 {
				slot_insert(d, fresh, cap, Slot_Kind(s >> 30), s & (1 << 30 - 1) - 1)
			}
		}
		if d.slot_mem != nil {
			runtime.heap_free(d.slot_mem)
		}
		d.slot_mem, d.built.slots = fresh, cap
		dtd_refresh(d)
	}
	slot_insert(d, d.slot_mem, d.built.slots, kind, index)
	return true
}

@(private)
slot_insert :: proc "contextless" (d: ^Dtd, slots: [^]u32, cap: u32, kind: Slot_Kind, index: u32) #no_bounds_check {
	mask := cap - 1
	for i := name_hash(kind, slot_name(&d.view, kind, index)) & mask; ; i = (i + 1) & mask {
		if slots[i] == 0 {
			slots[i] = u32(kind) << 30 | (index + 1)
			return
		}
	}
}

// Copies `b` into the bytes. Returns its offset, and false when memory runs out.
@(private)
dtd_bytes :: proc "contextless" (d: ^Dtd, b: []u8) -> (lo: u64, ok: bool) {
	if d.arena_n + u64(len(b)) > d.arena_cap {
		cap := max(256, 2 * d.arena_cap, d.arena_n + u64(len(b)))
		fresh := runtime.heap_resize(d.arena, int(cap))
		if fresh == nil {
			return 0, false
		}
		d.arena, d.arena_cap = ([^]u8)(fresh), cap
	}
	lo = d.arena_n
	intrinsics.mem_copy_non_overlapping(d.arena[lo:], raw_data(b), len(b))
	d.arena_n += u64(len(b))
	dtd_refresh(d)
	return lo, true
}

// Appends an entity. Returns its index, `NO_DECL` when memory runs out.
@(private)
dtd_entity :: proc "contextless" (d: ^Dtd, e: Entity) -> u32 {
	if d.built.entities == d.ent_cap {
		cap := max(16, 2 * d.ent_cap)
		fresh := runtime.heap_resize(d.ents, int(cap) * size_of(Entity))
		if fresh == nil {
			return NO_DECL
		}
		d.ents, d.ent_cap = ([^]Entity)(fresh), cap
	}
	i := d.built.entities
	d.ents[i] = e
	d.built.entities += 1
	dtd_refresh(d)
	return i
}

// Appends an attribute-list declaration. Returns its index, `NO_DECL` when memory runs out.
@(private)
dtd_attr :: proc "contextless" (d: ^Dtd, a: Attr_Decl) -> u32 {
	if d.built.attrs == d.att_cap {
		cap := max(16, 2 * d.att_cap)
		fresh := runtime.heap_resize(d.atts, int(cap) * size_of(Attr_Decl))
		if fresh == nil {
			return NO_DECL
		}
		d.atts, d.att_cap = ([^]Attr_Decl)(fresh), cap
	}
	i := d.built.attrs
	d.atts[i] = a
	d.built.attrs += 1
	dtd_refresh(d)
	return i
}

// The replacement text of entity `e`.
@(private)
entity_text :: #force_inline proc "contextless" (v: ^Dtd_View, src: []u8, e: ^Entity) -> []u8 #no_bounds_check {
	if .Stored in e.flags {
		return v.bytes[e.text_lo:][:e.text_n]
	}
	return src[e.text_lo:][:e.text_n]
}

// The declaration of attribute `name` of element `element`, nil for none.
@(private)
attr_decl :: proc "contextless" (v: ^Dtd_View, element, name: []u8) -> ^Attr_Decl #no_bounds_check {
	for i := dtd_find(v, .Element, element); i != NO_DECL; i = v.attrs[i].next {
		a := &v.attrs[i]
		if string(v.bytes[a.name_lo:][:a.name_n]) == string(name) {
			return a
		}
	}
	return nil
}

@(private)
saturating_add :: #force_inline proc "contextless" (a, b: u64) -> u64 {
	s, over := intrinsics.overflow_add(a, b)
	return max(u64) if over else s
}

// The fault at `p` with `detail`, for the DTD's readers.
@(private)
Dtd_Fault :: struct {
	at:     [^]u8,
	kind:   core.Fault_Kind,
	detail: Detail,
}
