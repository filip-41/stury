package xml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"

// The DTD's tables: the entities and the attribute-list declarations of the internal subset, a name table over both,
// and the bytes they name. The walk grows them in the read's allocator while it reads the subset, and reads them to the
// text's end. A document keeps a copy in its `Markup_Ext`, which its decodes read.

@(private)
NO_DECL :: max(u32)

@(private)
Dtd_Flag :: tape.Markup_Dtd_Flag
@(private)
Dtd_Flags :: tape.Markup_Dtd_Flags
@(private)
Entity_Flag :: tape.Markup_Entity_Flag
@(private)
Entity_Flags :: tape.Markup_Entity_Flags
@(private)
Entity :: tape.Markup_Entity
@(private)
Attr_Decl :: tape.Markup_Attribute

// The kinds of names the slots hold, in the slot's top two bits.
@(private)
Slot_Kind :: enum u32 {
	General,
	Parameter,
	Element, // the first attribute-list declaration of an element
}

@(private)
Dtd_View :: tape.Markup_Dtd

// A reference the walk entered: it reads the literal of `entity` and resumes at `resume`, before `end`, when the
// literal ends. `at` is the reference's `&`. `depth` and `tag` are the open count and the start tag of the element
// around the reference, which the literal must close as it found.
@(private)
Entity_Frame :: struct {
	resume: [^]u8,
	end:    [^]u8,
	at:     [^]u8,
	depth:  u64,
	tag:    [^]u8,
	entity: u32,
}

// The DTD a walk reads by. The tables of `view` grow in the arrays of `grab` while the internal subset is read, each
// holding the records its slice names in an array of `*_cap` of them, and `sealed` once the subset is read.
@(private)
Dtd :: struct {
	using view: Dtd_View,
	src:        []u8,
	// The internal subset's bytes in the text, where every node of an entity walked over its literal lies.
	subset_lo:  u64,
	subset_hi:  u64,
	ent_cap:    u32,
	att_cap:    u32,
	bytes_cap:  u64,
	sealed:     bool,
	// The expansion the references at the document's level have added, and the most it may reach.
	total:      u64,
	limit:      u64,
	tolerate:   bool, // `tape.Tolerance.Unread_Entity`
	took:       bool, // a reference to an entity whose text is not read was tolerated
	stack:      [^]Entity_Frame,
	depth:      u32,
	stack_cap:  u32,
	grab:       Grab, // what the DTD's memory comes from
}

// Makes the DTD of a walk over `src` with memory from `g`, or nil when memory runs out. `limit` is
// `Budget.expansion`.
@(private)
dtd_make :: proc "contextless" (src: []u8, tolerate: bool, limit: u64, g: Grab) -> ^Dtd {
	d := (^Dtd)(grab(g, size_of(Dtd), true))
	if d == nil {
		return nil
	}
	d.grab = g
	d.src = src
	d.tolerate = tolerate
	d.limit = limit if limit != 0 else tape.default_expansion(u64(len(src)))
	return d
}

@(private)
dtd_free :: proc "contextless" (d: ^Dtd) {
	if d == nil {
		return
	}
	ungrab(d.grab, raw_data(d.entities), int(d.ent_cap) * size_of(Entity))
	ungrab(d.grab, raw_data(d.attrs), int(d.att_cap) * size_of(Attr_Decl))
	ungrab(d.grab, raw_data(d.slots), len(d.slots) * size_of(u32))
	ungrab(d.grab, raw_data(d.bytes), int(d.bytes_cap))
	ungrab(d.grab, d.stack, int(d.stack_cap) * size_of(Entity_Frame))
	ungrab(d.grab, d, size_of(Dtd))
}

// A copy of the tables of `d` in a format data block of `allocator`, with the texts of its entities that lie in the
// text, from `base`, moved to its bytes, so a document decodes by it with no byte of the internal subset. Nil when
// memory runs out.
@(private)
dtd_keep :: proc "contextless" (d: ^Dtd, base: [^]u8, allocator: runtime.Allocator, ctx: ^runtime.Context) -> ^tape.Doc_Ext #no_bounds_check {
	n := u64(len(d.bytes))
	moved := n
	for e in d.entities {
		if e.flags & {.Stored, .External} == {} {
			moved += u64(e.text_n)
		}
	}
	if !dtd_reserve(d, moved) {
		return nil
	}
	kept := d.view
	kept.bytes = raw_data(d.bytes)[:moved]
	context = ctx^ if ctx != nil else runtime.default_context()
	ext, err := tape.ext_make(nil, tape.Markup_Ext{dtd = kept}, allocator)
	if err != nil {
		return nil
	}
	dtd := &(&ext.format.(tape.Markup_Ext)).dtd
	for &e in dtd.entities {
		if e.flags & {.Stored, .External} == {} {
			intrinsics.mem_copy_non_overlapping(raw_data(dtd.bytes[n:]), base[e.text_lo:], int(e.text_n))
			e.text_lo, e.flags = n, e.flags + {.Stored}
			n += u64(e.text_n)
		}
	}
	return ext
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
	if used := len(d.entities) + len(d.attrs); 2 * used >= len(d.slots) {
		cap := max(64, 2 * len(d.slots))
		fresh := ([^]u32)(grab(d.grab, cap * size_of(u32), true))[:cap]
		if raw_data(fresh) == nil {
			return false
		}
		for s in d.slots {
			if s != 0 {
				slot_insert(&d.view, fresh, Slot_Kind(s >> 30), s & (1 << 30 - 1) - 1)
			}
		}
		ungrab(d.grab, raw_data(d.slots), len(d.slots) * size_of(u32))
		d.slots = fresh
	}
	slot_insert(&d.view, d.slots, kind, index)
	return true
}

@(private)
slot_insert :: proc "contextless" (v: ^Dtd_View, slots: []u32, kind: Slot_Kind, index: u32) #no_bounds_check {
	mask := u32(len(slots) - 1)
	for i := name_hash(kind, slot_name(v, kind, index)) & mask; ; i = (i + 1) & mask {
		if slots[i] == 0 {
			slots[i] = u32(kind) << 30 | (index + 1)
			return
		}
	}
}

// Copies `b` into the bytes. Returns its offset, and false when memory runs out.
@(private)
dtd_bytes :: proc "contextless" (d: ^Dtd, b: []u8) -> (lo: u64, ok: bool) {
	lo = u64(len(d.bytes))
	dtd_reserve(d, lo + u64(len(b))) or_return
	d.bytes = raw_data(d.bytes)[:lo + u64(len(b))]
	intrinsics.mem_copy_non_overlapping(raw_data(d.bytes[lo:]), raw_data(b), len(b))
	return lo, true
}

// Gives the bytes room for `n` of them. Returns false when memory runs out.
@(private)
dtd_reserve :: proc "contextless" (d: ^Dtd, n: u64) -> bool {
	if n <= d.bytes_cap {
		return true
	}
	cap := max(256, 2 * d.bytes_cap, n)
	fresh := regrab(d.grab, raw_data(d.bytes), int(d.bytes_cap), int(cap))
	if fresh == nil {
		return false
	}
	d.bytes, d.bytes_cap = ([^]u8)(fresh)[:len(d.bytes)], cap
	return true
}

// Appends `v` to the records `items` of an array with room for `cap`. Returns its index, `NO_DECL` when memory runs
// out.
@(private)
dtd_push :: proc "contextless" (d: ^Dtd, items: ^[]$T, cap: ^u32, v: T) -> u32 {
	n := u32(len(items))
	if n == cap^ {
		room := max(16, 2 * cap^)
		fresh := regrab(d.grab, raw_data(items^), int(cap^) * size_of(T), int(room) * size_of(T))
		if fresh == nil {
			return NO_DECL
		}
		items^, cap^ = ([^]T)(fresh)[:n], room
	}
	items^ = raw_data(items^)[:n + 1]
	items[n] = v
	return n
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
	kind:   tape.Fault_Kind,
	detail: Detail,
}
