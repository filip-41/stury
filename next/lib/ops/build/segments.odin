package build

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// A part of a text's build, made by a builder of its own from a seam: a position past a comma inside containers opened
// before it. The builds of a text's segments run concurrently into a shared room for nodes and one for facts, each
// from the node and fact index where a single build would store its first node and fact, and are joined into the
// document a single build would make.
//
// A segment that starts inside containers has a scratch node for each, outermost first, placed past every segment's
// nodes. The builder writes into it the subtree size and child count of each container that closes in the segment. A
// further node represents the value completed before the seam, which an inline comment at the segment's start belongs
// to.
Segment :: struct {
	b:          Builder,
	allocator:  runtime.Allocator, // allocator of its `counts` (its builder's own allocator refuses every block)
	regs:       hook.Regs, // the builder's registers at the end of its walk
	depth:      int, // number of containers open at its seam
	first:      int, // index of the first node its walk stores
	scratch:    int, // index of the scratch node of the outermost container open at its seam
	containers: int, // containers opened in the segment itself, counted for `Budget.steps`
	// Set by the join: the segment's first node and first fact in the document, the node of the value before its seam
	// and the nodes of the containers open at its seam, outermost first.
	at, fact:   int,
	before:     tape.Node_Index,
	seam:       []tape.Node_Index,
}

// The index in a segment's room of the node representing the value completed before its seam.
@(private)
segment_before :: #force_inline proc "contextless" (s: ^Segment) -> int {
	return s.scratch + s.depth
}

// Returns a segment that stores up to `nodes` nodes in `room` from index `first`, its facts in `facts` and its open
// stack in `frames`. It starts at a seam inside containers of `kinds`, outermost first, whose scratch nodes it keeps
// from index `scratch` on, and the join writes the containers' document nodes into `seam`. With no kinds it starts at
// the text's start, as a builder does. Its builder is refused any more memory, so that its walk, which may run on
// another thread, calls no allocator. A refused allocation for `counts` leaves `b.err` set.
segment_start :: proc(src: []u8, format: ^tape.Format, room: []tape.Node, first, nodes, scratch: int, kinds: []tape.Kind, facts: []tape.Fact, frames: []u64, seam: []tape.Node_Index, allocator: runtime.Allocator) -> (s: Segment) {
	s.depth, s.first, s.scratch, s.seam, s.allocator = len(kinds), first, scratch, seam, allocator
	b := &s.b
	b.doc = {src = src, format = format, nodes = room, facts = facts[:0], allocator = {refuse_blocks, nil}}
	b.stack, b.facts, b.flags, b.closed, b.ctx, b.most = frames, facts, {.Borrowed}, tape.NO_NODE, context, max(int)
	b.first = tape.Node_Index(first)
	b.end = u64(uintptr(raw_data(room))) + u64((first + nodes) * size_of(tape.Node))
	// At most `nodes / MAX_CHILDREN` containers have `MAX_CHILDREN` children in the segment, and each gets one entry.
	b.counts.allocator = allocator
	if wide := nodes / int(tape.MAX_CHILDREN); wide > 0 {
		if b.err = reserve(&b.counts, wide); b.err == nil && cap(b.counts) < wide {
			b.err = .Out_Of_Memory
		}
		if b.err != nil {
			return
		}
	}
	s.regs = {a = u64(uintptr(raw_data(room))) + u64(first * size_of(tape.Node)), b = u64(tape.NO_NODE) << 32}
	if s.depth == 0 {
		return
	}
	for k, i in kinds {
		room[scratch + i] = {kind = k}
	}
	before := segment_before(&s)
	// An inline comment before the segment's first node belongs to the value before the seam. `n` and `b.closed` make
	// `builder_fact` find that value closed just before node `first`.
	room[before] = {n = u32(first) - u32(before)}
	b.closed = tape.Node_Index(before)
	b.stack[0] = u64(tape.NO_NODE) << 32
	for i in 1 ..< s.depth {
		b.stack[i] = u64(scratch + i - 1) << 32
	}
	s.regs.b, s.regs.c = u64(before - 1) << 32, u64(s.depth)
	return
}

// The nodes a segment's walk stored.
segment_nodes :: proc "contextless" (s: ^Segment) -> []tape.Node {
	return s.b.doc.nodes[s.first:builder_cursor(&s.b, s.regs)]
}

// Frees everything a segment holds except its rooms.
segment_free :: proc(s: ^Segment) {
	delete(s.b.counts)
	s.b = {}
}

@(private)
refuse_blocks :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	return nil, .Out_Of_Memory if mode != .Free && mode != .Free_All else nil
}

// A container open across a seam: its node in the document and its children counted so far.
@(private)
Open_Across :: struct {
	node:  tape.Node_Index,
	count: u64,
}

// Joins the segments `segs`, in text order, into a document. Each was walked from its seam to the next into `room` and
// `facts`, the last to the root value's end at `root_close`. A segment that stored fewer nodes or facts than planned
// moves down to follow the one before it. A pass over the containers open at each seam then gives those that cross it
// their sizes and counts, and the threads of `runner` give each fact its node. `joined` is false when a segment does
// not start inside the containers the one before it leaves open, which a read of the text in one walk would have
// found. When joined the document holds the rooms, else the rooms and the segments are left to the caller.
segments_join :: proc(segs: []Segment, room: []tape.Node, facts: []tape.Fact, root_close: u64, runner: ^tape.Runner, allocator: runtime.Allocator) -> (doc: tape.Document, joined: bool, err: runtime.Allocator_Error) {
	at, fact := 0, 0
	for &s in segs {
		own := segment_nodes(&s)
		if at != s.first {
			intrinsics.mem_copy(raw_data(room[at:]), raw_data(own), len(own) * size_of(tape.Node))
		}
		if len(s.b.doc.facts) > 0 && fact != int(uintptr(raw_data(s.b.facts)) - uintptr(raw_data(facts))) / size_of(tape.Fact) {
			intrinsics.mem_copy(raw_data(facts[fact:]), raw_data(s.b.doc.facts), len(s.b.doc.facts) * size_of(tape.Fact))
		}
		s.at, s.fact = at, fact
		at += len(own)
		fact += len(s.b.doc.facts)
	}
	total := at
	nodes := room
	doc = {src = segs[0].b.doc.src, format = segs[0].b.doc.format, allocator = allocator, root_close = root_close}
	open: [dynamic]Open_Across
	open.allocator = allocator
	defer delete(open)
	counts: [dynamic]tape.Child_Count
	counts.allocator = allocator
	defer if err != nil || !joined {
		delete(counts)
	}
	closed := tape.NO_NODE
	for &s in segs {
		if len(open) != s.depth {
			return {}, false, nil
		}
		for o, i in open[:s.depth] {
			if nodes[o.node].kind != nodes[s.scratch + i].kind {
				return {}, false, nil
			}
			s.seam[i] = o.node
		}
		s.before = tape.Node_Index(s.at - 1)
		if closed != tape.NO_NODE && int(closed) + int(nodes[closed].n) == s.at {
			s.before = closed
		}
		for n in s.b.counts {
			if s.depth == 0 || int(n.node) < s.scratch {
				if _, aerr := append(&counts, tape.Child_Count{segment_place(&s, n.node), n.count}); aerr != nil {
					return {}, false, aerr
				}
			}
		}
		if s.b.closed != tape.NO_NODE && (s.depth == 0 || int(s.b.closed) != segment_before(&s)) {
			closed = segment_place(&s, s.b.closed)
		}
		// The containers the segment closes, innermost first. The scratch node of each holds in `n` where it closed, as
		// an offset from that scratch node.
		for i := s.depth - 1; i >= 0 && nodes[s.scratch + i].n != 0; i -= 1 {
			scratch := nodes[s.scratch + i]
			count := u64(scratch.spelling & tape.MAX_CHILDREN)
			if count == u64(tape.MAX_CHILDREN) {
				for n in s.b.counts {
					if int(n.node) == s.scratch + i {
						count = u64(n.count)
					}
				}
			}
			o := open[i]
			total := o.count + count
			node := &nodes[o.node]
			node.n = u32(s.at + int(u32(s.scratch + i) + scratch.n - u32(s.first)) - int(o.node))
			node.spelling = node.spelling & tape.CONTAINER_STYLE | u16(min(total, u64(tape.MAX_CHILDREN)))
			if total >= u64(tape.MAX_CHILDREN) {
				if _, aerr := append(&counts, tape.Child_Count{o.node, u32(total)}); aerr != nil {
					return {}, false, aerr
				}
			}
			pop(&open)
		}
		// The levels open at the segment's end: the outer ones it left open, which gained its children, then its own.
		levels := int(s.regs.c)
		if levels < len(open) {
			return {}, false, nil
		}
		for level in 0 ..< levels {
			frame := s.regs.b if level == levels - 1 else s.b.stack[level + 1]
			node := int(frame >> 32)
			if level < len(open) {
				if node != s.scratch + level {
					return {}, false, nil
				}
				open[level].count += u64(u32(frame))
			} else {
				if node < s.first || s.depth > 0 && node >= s.scratch {
					return {}, false, nil
				}
				if _, aerr := append(&open, Open_Across{segment_place(&s, tape.Node_Index(node)), u64(u32(frame))}); aerr != nil {
					return {}, false, aerr
				}
			}
		}
	}
	if len(open) != 0 {
		return {}, false, nil
	}
	if len(counts) > 0 {
		slice.sort_by(counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
		if _, serr := shrink(&counts); serr != nil {
			return {}, false, serr
		}
		doc.counts = counts[:]
	} else {
		delete(counts)
	}
	// The document keeps the room whole, since `destroy` frees it as one block from its start, unless the unused part
	// exceeds a quarter of what it keeps. Then the room is resized to `total` nodes, which moves them to an exact block
	// when the allocator cannot shrink in place. A failed resize leaves the room whole. Large unbudgeted builds on the
	// default allocator move into a mapped node buffer to match single-threaded builds and release pages back to the OS.
	doc.nodes = room[:total]
	mapped_ok := false
	if total >= OS_RESERVE_MIN_NODES && allocator.procedure == runtime.default_allocator().procedure {
		if mapped, reserved, ok := tape.nodes_reserve(total); ok {
			committed := 0
			if tape.nodes_commit(mapped, &committed, total) {
				copy(mapped, room[:total])
				delete(room, allocator)
				doc.nodes = tape.nodes_trim_tail(mapped, total, reserved, committed)
				doc.flags += {.Mapped_Nodes}
				mapped_ok = true
			} else {
				_ = tape.nodes_trim_tail(mapped, 0, reserved, committed)
			}
		}
	}
	if !mapped_ok && len(room) - total > total / 4 {
		if raw, rerr := runtime.non_zero_mem_resize(raw_data(room), len(room) * size_of(tape.Node), total * size_of(tape.Node), align_of(tape.Node), allocator); rerr == nil {
			doc.nodes = ([^]tape.Node)(raw_data(raw))[:total]
		}
	}
	doc.facts = facts[:fact]
	if fact > 0 {
		c := Segment_Facts{segs = segs, doc = &doc}
		tape.fan_each(runner, len(c.segs), segment_facts, &c)
		for p in c.present {
			doc.present += p
		}
		builder_sort_facts(doc.facts)
	}
	joined = true
	return
}

// The node in the document of node `i` of segment `s`'s walk.
@(private)
segment_place :: #force_inline proc "contextless" (s: ^Segment, i: tape.Node_Index) -> tape.Node_Index {
	switch {
	case s.depth > 0 && i == tape.ROOT:
		// A foot past the root's close names the root, which no segment from a seam holds.
		return tape.ROOT
	case s.depth == 0 || int(i) < s.scratch:
		return tape.Node_Index(s.at + int(i) - s.first)
	case int(i) < s.scratch + s.depth:
		return s.seam[int(i) - s.scratch]
	}
	return s.before
}

@(private)
Segment_Facts :: struct {
	segs:    []Segment,
	doc:     ^tape.Document,
	present: [64]tape.Facts,
}

// Gives each segment's facts their nodes in the document and places its comments.
@(private)
segment_facts :: proc(arg: rawptr, k: int) {
	c := (^Segment_Facts)(arg)
	s := &c.segs[k]
	facts := c.doc.facts[s.fact:][:len(s.b.doc.facts)]
	present: tape.Facts
	for &f in facts {
		f.node = segment_place(s, f.node)
		if f.kind != .Comment {
			present += {f.kind}
		}
	}
	present += builder_place_comments(c.doc, facts, len(c.doc.nodes))
	intrinsics.atomic_or((^u32)(&c.present[k % len(c.present)]), transmute(u32)present)
}

@(private)
DUP_BUCKETS :: 128

// Hash-bucketed parallel duplicate-key check for `segments_join`: whole inner objects are checked in each segment with a
// stack scratch buffer (no heap allocs for <= 32 keys), while crossing keys scatter into `DUP_BUCKETS` node-ordered
// buckets and probe L2-resident open-addressed hash tables in parallel with no sorting.
@(require_results)
segments_dups :: proc(doc: ^tape.Document, segs: []Segment, dups: tape.Duplicates, rules: ^tape.Rules, runner: ^tape.Runner) -> tape.Error {
	if !dups_apply(doc, dups) {
		return nil
	}
	mapped_before := len(doc.nodes) if .Mapped_Nodes in doc.flags else 0
	allocator := doc.allocator
	locked := Locked_Allocator{backing = allocator}
	worker_alloc := locked_allocator(&locked)
	r := Repeats{at = tape.NO_NODE}
	defer delete(r.drops, allocator)
	err: runtime.Allocator_Error
	parts: []Dup_Part
	parts, err = make([]Dup_Part, len(segs), allocator)
	if err != nil {
		return dups_end(doc, &r, err, rules)
	}
	defer {
		for p in parts {
			delete(p.keys)
			delete(p.scratch)
		}
		delete(parts, allocator)
	}
	if dups != .Refuse {
		if r.drops, err = make([]u64, (len(doc.nodes) + 63) / 64, allocator); err != nil {
			return dups_end(doc, &r, err, rules)
		}
	}
	for &p in parts {
		p.r = {at = tape.NO_NODE, drops = r.drops}
		p.keys.allocator = worker_alloc
		p.scratch.allocator = worker_alloc
	}
	j := Dup_Job {
		doc          = doc,
		segs         = segs,
		dups         = dups,
		parts        = parts,
		drops        = r.drops,
		worker_alloc = worker_alloc,
		refuse_limit = tape.NO_NODE,
	}
	tape.fan_each(runner, len(segs), dup_scan_part, &j)
	crossing := 0
	for p in parts {
		r.at = min(r.at, p.r.at)
		r.dropped ||= p.r.dropped
		crossing += p.crossing
		if p.err != nil {
			err = p.err
		}
	}
	if crossing > 0 && err == nil {
		if crossing <= FEW_KEYS {
			small: [FEW_KEYS]Hashed_Key = ---
			at := 0
			for p in parts {
				copy(small[at:], p.keys[:p.crossing])
				at += p.crossing
			}
			err = repeats_in(doc, small[:crossing], dups, &r)
			return dups_end_mapped(doc, &r, err, rules, mapped_before)
		}
		j.keys, err = non_zero_make([]Hashed_Key, crossing, allocator)
		if err != nil {
			return dups_end_mapped(doc, &r, err, rules, mapped_before)
		}
		defer delete(j.keys, allocator)
		cur := u32(0)
		for b in 0 ..< DUP_BUCKETS {
			j.b_ends[b] = int(cur)
			for &p in parts {
				p.offsets[b] = cur
				cur += p.counts[b]
			}
		}
		j.b_ends[DUP_BUCKETS] = int(cur)
		tape.fan_each(runner, len(segs), dup_scatter_part, &j)
		// Release per-segment key lists before workers allocate probe hash tables.
		for &p in parts {
			delete(p.keys)
			p.keys = {}
			delete(p.scratch)
			p.scratch = {}
		}
		j.refuse_limit = r.at
		for &a in j.bucket_at {
			a = tape.NO_NODE
		}
		tape.fan(runner, dup_check_buckets, &j)
		for b in 0 ..< DUP_BUCKETS {
			r.at = min(r.at, j.bucket_at[b])
			r.dropped ||= j.bucket_dropped[b]
			if j.bucket_err[b] != nil {
				err = j.bucket_err[b]
			}
		}
	}
	return dups_end_mapped(doc, &r, err, rules, mapped_before)
}

@(private = "file")
dups_end_mapped :: proc(doc: ^tape.Document, r: ^Repeats, refused: runtime.Allocator_Error, rules: ^tape.Rules, mapped_before: int) -> tape.Error {
	e := dups_end(doc, r, refused, rules)
	if e == nil && mapped_before > 0 && .Mapped_Nodes in doc.flags && len(doc.nodes) < mapped_before {
		doc.nodes = tape.nodes_trim_tail(doc.nodes, len(doc.nodes), tape.nodes_mapped_bytes(mapped_before))
		if len(doc.nodes) == 0 {
			doc.flags -= {.Mapped_Nodes}
		}
	}
	return e
}

@(private)
Dup_Part :: struct {
	r:        Repeats,
	keys:     [dynamic]Hashed_Key,
	scratch:  [dynamic]Hashed_Key,
	counts:   [DUP_BUCKETS]u32,
	offsets:  [DUP_BUCKETS]u32,
	crossing: int,
	err:      runtime.Allocator_Error,
}

@(private)
Dup_Job :: struct {
	doc:            ^tape.Document,
	segs:           []Segment,
	dups:           tape.Duplicates,
	parts:          []Dup_Part,
	keys:           []Hashed_Key,
	drops:          []u64,
	worker_alloc:   runtime.Allocator,
	refuse_limit:   tape.Node_Index,
	b_ends:         [DUP_BUCKETS + 1]int,
	next_bucket:    int,
	bucket_at:      [DUP_BUCKETS]tape.Node_Index,
	bucket_dropped: [DUP_BUCKETS]bool,
	bucket_err:     [DUP_BUCKETS]runtime.Allocator_Error,
}

@(private)
dup_scan_part :: proc(arg: rawptr, k: int) #no_bounds_check {
	j := (^Dup_Job)(arg)
	doc := j.doc
	s, p := &j.segs[k], &j.parts[k]
	lo, hi := s.at, j.segs[k + 1].at if k + 1 < len(j.segs) else len(doc.nodes)
	stack := s.b.stack
	top := 0
	for node in s.seam {
		stack[top] = u64(node) << 1 | 1
		top += 1
	}
	inline_scratch: [32]Hashed_Key = ---
	for i in lo ..< hi {
		for top > 0 && int(stack[top - 1] >> 1) + int(doc.nodes[stack[top - 1] >> 1].n) <= i {
			top -= 1
		}
		node := doc.nodes[i]
		if node.role == .Key && top > 0 && stack[top - 1] & 1 != 0 {
			object := tape.Node_Index(stack[top - 1] >> 1)
			h := doc.format.key_hash(doc.src, node)
			if _, p.err = append(&p.keys, Hashed_Key{h, object, tape.Node_Index(i)}); p.err != nil {
				return
			}
			p.counts[h >> 25] += 1
			p.crossing += 1
		}
		if node.kind <= .Plain {
			continue
		}
		whole := i + int(node.n) <= hi
		if node.kind == .Object && whole && p.err == nil {
			inline_n := 0
			overflow := false
			for m := tape.Node_Index(i) + 1; int(m) < i + int(node.n); m = tape.node_after(doc, tape.node_after(doc, m)) {
				hk := Hashed_Key{doc.format.key_hash(doc.src, doc.nodes[m]), 0, m}
				if !overflow && inline_n < len(inline_scratch) {
					inline_scratch[inline_n] = hk
					inline_n += 1
					continue
				}
				if !overflow {
					clear(&p.scratch)
					if _, p.err = append(&p.scratch, ..inline_scratch[:]); p.err != nil {
						return
					}
					overflow = true
				}
				if _, p.err = append(&p.scratch, hk); p.err != nil {
					return
				}
			}
			obj_keys := p.scratch[:] if overflow else inline_scratch[:inline_n]
			if p.err = repeats_in(doc, obj_keys, j.dups, &p.r); p.err != nil {
				return
			}
		}
		stack[top] = u64(i) << 1 | u64(!whole)
		top += 1
	}
}

@(private)
dup_scatter_part :: proc(arg: rawptr, k: int) #no_bounds_check {
	j := (^Dup_Job)(arg)
	p := &j.parts[k]
	offs := p.offsets
	for hk in p.keys[:p.crossing] {
		b := hk.hash >> 25
		pos := offs[b]
		offs[b] = pos + 1
		j.keys[pos] = hk
	}
}

@(private)
dup_check_buckets :: proc(arg: rawptr) #no_bounds_check {
	j := (^Dup_Job)(arg)
	doc := j.doc
	slots: [dynamic]u32
	slots.allocator = j.worker_alloc
	defer delete(slots)
	for {
		b := intrinsics.atomic_add(&j.next_bucket, 1)
		if b >= DUP_BUCKETS {
			return
		}
		lo, hi := j.b_ends[b], j.b_ends[b + 1]
		m := hi - lo
		if m <= 1 {
			continue
		}
		sl := j.keys[lo:hi]
		if j.dups == .Refuse && sl[0].node >= j.refuse_limit {
			continue
		}
		if m <= FEW_KEYS {
			br := Repeats{at = j.refuse_limit, drops = j.drops}
			if berr := repeats_in(doc, sl, j.dups, &br); berr != nil {
				j.bucket_err[b] = berr
				return
			}
			j.bucket_at[b] = br.at
			j.bucket_dropped[b] = br.dropped
			continue
		}
		cap_u64 := u64(32)
		for cap_u64 < u64(m) * 2 {
			cap_u64 *= 2
		}
		if cap_u64 > min(u64(max(int) / size_of(u32)), u64(max(u32))) {
			j.bucket_err[b] = .Out_Of_Memory
			return
		}
		table_cap := int(cap_u64)
		if rerr := non_zero_reserve(&slots, table_cap); rerr != nil || cap(slots) < table_cap {
			j.bucket_err[b] = rerr if rerr != nil else .Out_Of_Memory
			return
		}
		tbl := ([^]u32)(raw_data(slots))[:table_cap]
		runtime.mem_zero(raw_data(tbl), table_cap * size_of(u32))
		mask := u32(table_cap - 1)
		local_at := j.refuse_limit
		local_dropped := false
		for hk, i in sl {
			if j.dups == .Refuse && hk.node >= local_at {
				break
			}
			slot := (hk.hash ~ (u32(hk.object) * 0x9E3779B9)) & mask
			for {
				entry := tbl[slot]
				if entry == 0 {
					tbl[slot] = u32(i + 1)
					break
				}
				prev := &sl[entry - 1]
				if prev.hash == hk.hash && prev.object == hk.object && tape.same_keys(doc.format, doc.src, doc.nodes[prev.node], doc.src, doc.nodes[hk.node]) {
					switch j.dups {
					case .Refuse:
						local_at = min(local_at, hk.node)
					case .First:
						intrinsics.atomic_or(&j.drops[hk.node / 64], 1 << uint(hk.node % 64))
						local_dropped = true
					case .Last:
						intrinsics.atomic_or(&j.drops[prev.node / 64], 1 << uint(prev.node % 64))
						local_dropped = true
						tbl[slot] = u32(i + 1)
					case .Default, .All, .Group:
					}
					break
				}
				slot = (slot + 1) & mask
			}
		}
		j.bucket_at[b] = local_at
		j.bucket_dropped[b] = local_dropped
	}
}
