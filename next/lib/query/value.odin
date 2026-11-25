package query

import "base:runtime"
import "core:math/big"
import "stury:lib/core/tape"

// The values every query language evaluates over: absent, null, booleans, exact integers, doubles, strings, arrays and
// objects. A value is 16 bytes. A string, a big integer and a built container live in a block of the `Heap` with a
// reference count, so a value is copied by `retain` and given up by `release`, and a container held once is changed
// in place. A value read out of a document stays a node of it, holding the document's block, until it is changed.

// How a value is held.
Kind :: enum u8 {
	Absent, // no value: a member or element a read did not find
	Null,
	False,
	True,
	Int, // `i`
	Double, // `f`
	Big, // an integer past `i64`, `p` a `^Big_Block`
	String, // `s[:n]`, in a `Str_Block` when `held`, else borrowed from memory that outlives the run
	Array, // `p` a `^Array_Block`
	Object, // `p` a `^Object_Block`
	Node, // node `n` of the document of the `^Doc_Block` at `p`: a number, a string with no escape, or a container
}

// What a value is, whatever holds it, in no language's order.
Type :: enum u8 {
	Absent,
	Null,
	False,
	True,
	Number,
	String,
	Array,
	Object,
}

Value :: struct {
	using _: struct #raw_union {
		i: i64,
		f: f64,
		p: rawptr,
		s: [^]u8,
	},
	n:       u32, // a string's length, a node's index
	kind:    Kind,
	// The value holds a reference on its block, given up by `release`. A value with no block, or whose block outlives
	// the run (a program's constant), holds none.
	held:    bool,
	// A mark the caller may set and the engine carries with the value and never reads.
	mark:    u16,
}

#assert(size_of(Value) == 16)

ABSENT :: Value{}
NULL :: Value{kind = .Null}
TRUE :: Value{kind = .True}
FALSE :: Value{kind = .False}

int_value :: #force_inline proc "contextless" (i: i64) -> Value {
	return {i = i, kind = .Int}
}

double_value :: #force_inline proc "contextless" (f: f64) -> Value {
	return {f = f, kind = .Double}
}

bool_value :: #force_inline proc "contextless" (b: bool) -> Value {
	return TRUE if b else FALSE
}

// A string of bytes the run does not own, which outlive every value made of them.
text_borrowed :: #force_inline proc "contextless" (s: string) -> Value {
	return {s = raw_data(s), n = u32(len(s)), kind = .String}
}

@(private)
BLOCK_HAS_HELD :: u8(1)
@(private)
BLOCK_HAS_CONTAINER :: u8(2)
@(private)
BLOCK_HAS_PARTIAL :: u8(4)
@(private)
BLOCK_HAS_DOC :: u8(8) // `Str_Block` carries a retained `^Doc_Block` at its tail and `node` in its header
@(private)
BLOCK_SYNTHETIC :: u8(16) // `Doc_Block` parsed from a synthetic string (e.g. `fromjson`), not an input document

// The header of every block a value holds.
Block :: struct {
	rc:        u32,
	class:     u8, // its size class in the heap, `DIRECT` for one allocated on its own
	flags:     u8, // `BLOCK_HAS_HELD`, `BLOCK_HAS_CONTAINER`, `BLOCK_HAS_PARTIAL`, `BLOCK_HAS_DOC`
	slot_log2: u8, // for `Object_Block`: log2(slot_count), 0 when no table
	_:         u8,
}

@(private)
Str_Block :: struct {
	using block: Block,
	cap:         u32, // the bytes after the header (including tail `^Doc_Block` when `BLOCK_HAS_DOC`)
	node:        u32, // document node index when `BLOCK_HAS_DOC`
}

@(private)
str_doc_slot :: #force_inline proc "contextless" (s: ^Str_Block) -> ^^Doc_Block {
	return (^^Doc_Block)(uintptr(s) + size_of(Str_Block) + uintptr(s.cap) - size_of(^Doc_Block))
}

@(private)
Big_Block :: struct {
	using block: Block,
	value:       big.Int,
}

// A built array's elements follow its header.
@(private)
Array_Block :: struct {
	using block: Block,
	next:        ^Block, // the next block of the heap's list of blocks being freed
	len, cap:    u32,
}

// A built object's entries follow its header, in insertion order, with no key twice. Past `SMALL_ENTRIES` entries a
// table of `slots` finds a key: each slot is an entry's index plus one, 0 for none, at most half full.
// `next_or_slots` holds `[^]u32` while alive (`slot_log2 > 0`) and `^Block` while on `Heap.dying` (after slots are freed).
@(private)
Object_Block :: struct {
	using block:   Block,
	next_or_slots: rawptr,
	len, cap:      u32,
}
#assert(size_of(Object_Block) == 24 when size_of(rawptr) == 8 else size_of(Object_Block) == 20)

@(private)
object_slots :: #force_inline proc "contextless" (o: ^Object_Block) -> [^]u32 {
	return ([^]u32)(o.next_or_slots) if o.slot_log2 != 0 else nil
}

@(private)
object_slot_count :: #force_inline proc "contextless" (o: ^Object_Block) -> u32 {
	return u32(1) << o.slot_log2 if o.slot_log2 != 0 else 0
}

@(private)
free_object_slots :: #force_inline proc(h: ^Heap, o: ^Object_Block) {
	if o.slot_log2 != 0 {
		bytes := (u64(1) << o.slot_log2) * size_of(u32)
		runtime.mem_free_with_size(o.next_or_slots, int(bytes), h.allocator)
		h.used -= bytes
		o.next_or_slots = nil
		o.slot_log2 = 0
	}
}

Entry :: struct {
	key, value: Value,
}

// A document the run's values read. Its nodes, text and index are freed with the block when `owned`.
Doc_Block :: struct {
	using block: Block,
	doc:         tape.Document,
	index:       tape.Doc_Index,
	owned:       bool,
}

// The most entries an object finds a key in by comparing each.
@(private)
SMALL_ENTRIES :: 8

// The block sizes the heap keeps free lists of: 16-byte steps to 256, then doubling to 64 KiB.
@(private, rodata)
CLASS_SIZES := [?]u32{
	16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 256,
	512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
}
@(private)
DIRECT :: u8(0xFF)

// Where a run's values live: its allocator, the free lists of its block sizes, the bytes it holds against its memory
// budget, and the error the last failed operation set. One thread uses a heap at a time.
Heap :: struct {
	allocator: runtime.Allocator,
	free:      [len(CLASS_SIZES)]rawptr,
	used:      u64, // bytes taken from `allocator`, free-listed ones included
	limit:     u64, // 0 for none
	err:       Error,
	dying:     ^Block, // containers whose children `free_tree` has yet to give up
	slabs:     ^Slab, // the memory the free lists' blocks are cut from, freed with the heap
	cut:       [len(CLASS_SIZES)]u8, // how many slabs of each size class the heap has cut, which sizes the next
	// The deepest level, the outermost value's being 0, an operation goes down to in a value or a path: 0 for
	// `tape.DEFAULT_DEPTH`.
	depth:     int,
	// A read reached a value a partial document did not keep, which it read as absent.
	tainted:         bool,
	// Retain document origins on null, boolean, and decoded string scalars (enabled only when `where` runs).
	keep_origins:    bool,
	// Optional hook (wired by `Overlay` in Phase 2A) backing writes to fact paths.
	write_fact:      Fact_Writer,
	write_fact_data: rawptr,
}

// What an operation gives beside its value: `.Error` with the error in `Heap.err`.
Status :: enum u8 {
	Ok,
	Error,
}

heap_init :: proc(h: ^Heap, allocator: runtime.Allocator, memory_limit: u64 = 0, depth := 0) {
	h^ = {allocator = allocator, limit = memory_limit, depth = depth}
}

// The deepest level an operation of heap `h` goes down to.
depth_limit :: #force_inline proc "contextless" (h: ^Heap) -> int {
	return h.depth if h.depth > 0 else tape.DEFAULT_DEPTH
}

// Frees the heap's blocks and the error. Values still held lose their blocks, so the caller releases them first.
heap_destroy :: proc(h: ^Heap) {
	clear_error(h)
	for s := h.slabs; s != nil; {
		next := s.next
		runtime.mem_free_with_size(s, s.size, h.allocator)
		s = next
	}
	h.slabs = nil
	h.free = {}
	h.cut = {}
	h.used = 0
}

// A run of blocks of one size class, taken from the allocator at once, with this header before them.
@(private)
Slab :: struct {
	next: ^Slab,
	size: int,
}

// The slab's blocks start past its header at 16 bytes, their alignment.
@(private)
SLAB_HEAD :: 16

#assert(size_of(Slab) <= SLAB_HEAD)

// The blocks a class's first slab holds: each later slab of the class holds twice the last, up to `SLAB_BYTES`.
@(private)
SLAB_FIRST :: 4
@(private)
SLAB_BYTES :: 256 * 1024

// Cuts a slab of class `class`'s blocks of `room` bytes, gives the first and free-lists the rest.
@(private, cold)
cut_slab :: proc(h: ^Heap, class: u8, room: int) -> (res: ^Block, status: Status) #no_bounds_check {
	count := max(1, min(SLAB_FIRST << h.cut[class], SLAB_BYTES / room))
	if h.limit != 0 && h.used + u64(room) > h.limit {
		return nil, fail_memory(h)
	}
	if h.limit != 0 {
		count = max(1, min(count, int((h.limit - h.used) / u64(room))))
	}
	size := SLAB_HEAD + count * room
	mem, err := runtime.mem_alloc_non_zeroed(size, 16, h.allocator)
	if err != nil {
		return nil, fail_memory(h)
	}
	s := (^Slab)(raw_data(mem))
	s^ = {next = h.slabs, size = size}
	h.slabs = s
	h.cut[class] = min(h.cut[class] + 1, 15)
	h.used += u64(count * room)
	first := uintptr(s) + SLAB_HEAD
	for i := count - 1; i >= 1; i -= 1 {
		at := rawptr(first + uintptr(i * room))
		(^rawptr)(at)^ = h.free[class]
		h.free[class] = at
	}
	b := (^Block)(first)
	b^ = {rc = 1, class = class}
	return b, .Ok
}

// Direct block `b` of `size` bytes grown to `to` bytes, moved if the allocator has to, its contents kept.
@(private)
resize_direct :: proc(h: ^Heap, b: ^Block, size, to: int) -> (res: ^Block, status: Status) {
	if h.limit != 0 && h.used + u64(to - size) > h.limit {
		return nil, fail_memory(h)
	}
	mem, err := runtime.mem_resize(b, size, to, 16, h.allocator)
	if err != nil {
		return nil, fail_memory(h)
	}
	h.used += u64(to - size)
	return (^Block)(raw_data(mem)), .Ok
}

// A block of at least `size` bytes, its header's count 1, or `.Error` with `.Memory` set.
@(require_results)
alloc_block :: proc(h: ^Heap, size: int) -> (res: ^Block, status: Status) #no_bounds_check {
	class := size_class(size)
	if class != DIRECT {
		if head := h.free[class]; head != nil {
			h.free[class] = (^rawptr)(head)^
			b := (^Block)(head)
			b^ = {rc = 1, class = class}
			return b, .Ok
		}
		return cut_slab(h, class, int(CLASS_SIZES[class]))
	}
	room := size
	if h.limit != 0 && h.used + u64(room) > h.limit {
		return nil, fail_memory(h)
	}
	mem, err := runtime.mem_alloc_non_zeroed(room, 16, h.allocator)
	if err != nil {
		return nil, fail_memory(h)
	}
	h.used += u64(room)
	b := (^Block)(raw_data(mem))
	b^ = {rc = 1, class = class}
	return b, .Ok
}

// An allocator over the heap's own that counts what it holds against the memory budget, for memory a run keeps beside
// its values. Each allocation sits after a header that holds its size and where its own block starts, so a free needs
// nothing from the caller.
heap_allocator :: proc "contextless" (h: ^Heap) -> runtime.Allocator {
	return {procedure = counted_proc, data = h}
}

@(private = "file")
Counted_Header :: struct {
	room:  int, // the bytes taken from the heap's allocator, the header's padding included
	start: int, // the bytes from the block's start to the allocation
}

@(private = "file")
counted_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_ptr: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	h := (^Heap)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		start := max(alignment, size_of(Counted_Header))
		room := size + start
		if h.limit != 0 && h.used + u64(room) > h.limit {
			return nil, .Out_Of_Memory
		}
		raw: []byte
		err: runtime.Allocator_Error
		if mode == .Alloc {
			raw, err = runtime.mem_alloc(room, start, h.allocator, loc)
		} else {
			raw, err = runtime.mem_alloc_non_zeroed(room, start, h.allocator, loc)
		}
		if err != nil {
			return nil, err
		}
		(^Counted_Header)(raw_data(raw)[start - size_of(Counted_Header):])^ = {room, start}
		h.used += u64(room)
		return raw[start:][:size], nil
	case .Free:
		if old_ptr == nil {
			return nil, nil
		}
		head := (^Counted_Header)(uintptr(old_ptr) - size_of(Counted_Header))^
		h.used -= u64(head.room)
		runtime.mem_free_with_size(rawptr(uintptr(old_ptr) - uintptr(head.start)), head.room, h.allocator, loc)
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		if old_ptr == nil {
			return counted_proc(data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		}
		grown, err := counted_proc(data, .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		if err != nil {
			return nil, err
		}
		copy(grown, ([^]byte)(old_ptr)[:min(old_size, size)])
		if mode == .Resize && size > old_size {
			runtime.mem_zero(raw_data(grown)[old_size:], size - old_size)
		}
		_, _ = counted_proc(data, .Free, 0, 0, old_ptr, old_size, loc)
		return grown, nil
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_ptr)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}

// The bytes a block of `size` takes, past which it is moved to grow.
@(private)
block_room :: #force_inline proc "contextless" (size: int) -> int {
	class := size_class(size)
	return int(CLASS_SIZES[class]) if class != DIRECT else size
}

@(private)
size_class :: #force_inline proc "contextless" (size: int) -> u8 {
	if size <= 256 {
		return u8(max(size - 1, 0) >> 4)
	}
	if size > 65536 {
		return DIRECT
	}
	c := u8(16)
	for s := 512; s < size; s <<= 1 {
		c += 1
	}
	return c
}

// Gives back block `b` of `size` bytes, which a caller made with `alloc_block` and holds no value in.
give_back :: proc(h: ^Heap, b: ^Block, size: int) {
	free_block(h, b, block_room(size))
}

// Gives back a block whose count reached 0, its children already given up. `size` is its size for a direct one.
@(private)
free_block :: proc(h: ^Heap, b: ^Block, size: int) #no_bounds_check {
	if class := b.class; class != DIRECT {
		(^rawptr)(b)^ = h.free[class]
		h.free[class] = b
		return
	}
	h.used -= u64(size)
	runtime.mem_free_with_size(b, size, h.allocator)
}

// The block value `v` holds, nil for none.
@(private)
block_of :: #force_inline proc "contextless" (v: Value) -> ^Block {
	if !v.held {
		return nil
	}
	if v.kind == .String {
		return (^Block)(uintptr(v.s) - size_of(Str_Block))
	}
	return (^Block)(v.p)
}

// `v` once more, for a copy kept beside it.
retain :: #force_inline proc "contextless" (v: Value) -> Value {
	if b := block_of(v); b != nil {
		b.rc += 1
	}
	return v
}

// Gives up the reference `v` holds, freeing its block and what only it held once none is left.
release :: #force_inline proc(h: ^Heap, v: Value) {
	if b := block_of(v); b != nil {
		b.rc -= 1
		if b.rc == 0 {
			free_tree(h, v.kind, b)
		}
	}
}

// Whether the block of `v` is held by `v` alone, so an operation may change it in place.
unique :: #force_inline proc "contextless" (v: Value) -> bool {
	b := block_of(v)
	return b != nil && b.rc == 1
}

// Frees block `b` of kind `kind` and every block only it held, with no recursion: containers wait on `Heap.dying`.
@(private)
free_tree :: #force_no_inline proc(h: ^Heap, kind: Kind, b: ^Block) #no_bounds_check {
	if free_flat(h, kind, b) {
		return
	}
	free_one(h, kind, b)
	for h.dying != nil {
		c := h.dying
		if c.class == DYING_ARRAY {
			a := (^Array_Block)(c)
			h.dying = a.next
			for v in array_items(a) {
				drop_child(h, v)
			}
			c.class = a_class(a)
			free_block(h, c, array_size(int(a.cap)))
		} else {
			o := (^Object_Block)(c)
			h.dying = (^Block)(o.next_or_slots)
			for e in object_entries(o) {
				drop_child(h, e.key)
				drop_child(h, e.value)
			}
			c.class = o_class(o)
			free_block(h, c, object_size(int(o.cap)))
		}
	}
}

// A container block waiting on `Heap.dying` keeps its size class in the high bits of its count, which is 0 there.
@(private)
DYING_ARRAY :: u8(0xFE)
@(private)
DYING_OBJECT :: u8(0xFD)

@(private)
a_class :: #force_inline proc "contextless" (a: ^Array_Block) -> u8 {
	return u8(a.rc >> 24)
}

@(private)
o_class :: #force_inline proc "contextless" (o: ^Object_Block) -> u8 {
	return u8(o.rc >> 24)
}

@(private)
drop_child :: #force_inline proc(h: ^Heap, v: Value) {
	if b := block_of(v); b != nil {
		b.rc -= 1
		if b.rc == 0 && !free_flat(h, v.kind, b) {
			free_one(h, v.kind, b)
		}
	}
}

// Frees container block `b` at once when none of its children is a container, false for any other block.
// Containers holding only unheld scalars skip the child loop completely.
@(private)
free_flat :: proc(h: ^Heap, kind: Kind, b: ^Block) -> bool #no_bounds_check {
	#partial switch kind {
	case .Array:
		a := (^Array_Block)(b)
		if b.flags & BLOCK_HAS_HELD == 0 {
			free_block(h, b, array_size(int(a.cap)))
			return true
		}
		if b.flags & BLOCK_HAS_CONTAINER != 0 {
			return false
		}
		for x in array_items(a) {
			drop_scalar(h, x)
		}
		free_block(h, b, array_size(int(a.cap)))
		return true
	case .Object:
		o := (^Object_Block)(b)
		if b.flags & BLOCK_HAS_HELD == 0 {
			free_object_slots(h, o)
			free_block(h, b, object_size(int(o.cap)))
			return true
		}
		if b.flags & BLOCK_HAS_CONTAINER != 0 {
			return false
		}
		for e in object_entries(o) {
			drop_scalar(h, e.key)
			drop_scalar(h, e.value)
		}
		free_object_slots(h, o)
		free_block(h, b, object_size(int(o.cap)))
		return true
	}
	return false
}

// Gives up a string's or a big integer's reference, which holds no other block.
@(private)
drop_scalar :: #force_inline proc(h: ^Heap, v: Value) {
	if b := block_of(v); b != nil {
		b.rc -= 1
		if b.rc == 0 {
			free_one(h, v.kind, b)
		}
	}
}

// Frees a block with no child, or puts a container on `Heap.dying`.
@(private)
free_one :: proc(h: ^Heap, kind: Kind, b: ^Block) {
	#partial switch kind {
	case .String:
		s := (^Str_Block)(b)
		if s.flags & BLOCK_HAS_DOC != 0 {
			d := str_doc_slot(s)^
			d.rc -= 1
			if d.rc == 0 {
				free_one(h, .Node, d)
			}
		}
		free_block(h, b, int(s.cap) + size_of(Str_Block))
	case .Big:
		x := (^Big_Block)(b)
		big.int_destroy(&x.value)
		free_block(h, b, size_of(Big_Block))
	case .Array:
		a := (^Array_Block)(b)
		a.rc = u32(b.class) << 24
		b.class = DYING_ARRAY
		a.next = h.dying
		h.dying = b
	case .Object:
		o := (^Object_Block)(b)
		free_object_slots(h, o)
		o.rc = u32(b.class) << 24
		b.class = DYING_OBJECT
		o.next_or_slots = h.dying
		h.dying = b
	case .Node:
		d := (^Doc_Block)(b)
		tape.destroy_index(&d.index)
		if d.owned {
			tape.destroy_document(&d.doc)
		}
		free_block(h, b, size_of(Doc_Block))
	}
}

// The value of a document the run reads: its root, holding the document's block, which frees the document with its last
// value when `owned`. `.Absent` for a document with no root, as a partial read that kept none.
@(require_results)
document_value :: proc(h: ^Heap, doc: tape.Document, owned: bool, synthetic := false) -> (res: Value, status: Status) {
	b := alloc_block(h, size_of(Doc_Block)) or_return
	d := (^Doc_Block)(b)
	d.doc, d.owned = doc, owned
	if synthetic {
		d.flags |= BLOCK_SYNTHETIC
	}
	d.index = {allocator = heap_allocator(h)}
	whole := Value{p = d, n = u32(tape.ROOT), kind = .Node, held = true}
	root_idx, p := tape.root(reader(d))
	note_presence(h, p)
	if p != .Found {
		release(h, whole)
		return ABSENT, .Ok
	}
	whole.n = u32(root_idx)
	if k := doc.nodes[root_idx].kind; k != .Array && k != .Object {
		// A scalar root is the value it reads as, a text decoded, keeping its document origin unless synthetic.
		defer release(h, whole)
		return node_value(h, d, root_idx, !synthetic)
	}
	return whole, .Ok
}

// The bytes of the heap's blocks in use: what it took from its allocator, but its free lists.
heap_live :: proc(h: ^Heap) -> u64 {
	free: u64
	for head, class in h.free {
		for b := head; b != nil; b = (^rawptr)(b)^ {
			free += u64(CLASS_SIZES[class])
		}
	}
	return h.used - free
}

// Sets `Heap.err` and returns `.Error`. The operands are retained, as the error outlives them.
fail :: proc(h: ^Heap, kind: Error_Kind, op: Op, a := ABSENT, b := ABSENT, detail := "") -> Status {
	clear_error(h)
	h.err = {kind = kind, op = op, a = retain(a), b = retain(b), detail = detail}
	return .Error
}

@(private, cold)
fail_memory :: proc(h: ^Heap) -> Status {
	clear_error(h)
	h.err = {kind = .Memory}
	return .Error
}

// Gives up the error `Heap.err` holds, and leaves none.
clear_error :: proc(h: ^Heap) {
	release(h, h.err.a)
	release(h, h.err.b)
	release(h, h.err.path)
	h.err = {}
}

// The error `Heap.err` holds, which the caller now owns, leaving none.
take_error :: proc(h: ^Heap) -> Error {
	e := h.err
	h.err = {}
	return e
}

destroy_error :: proc(h: ^Heap, e: ^Error) {
	release(h, e.a)
	release(h, e.b)
	release(h, e.path)
	e^ = {}
}
