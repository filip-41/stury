// `doc <lane> <file>`: stury's document under one lane, gb_per_s from the median of ten timed calls after two
// warm-ups, and a checksum of what the lane read. A `.csv` or `.tsv` file is a headed dsv text, `.jsonc` and `.json5`
// pick their spec, and a `.yaml`, `.toml`, `.xml`, `.html` or `.cbor` file is read through `core` as that format, each
// node as the kind the format resolves it to.
package doc

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import core "../../../../core"
import "../../../formats"
import "../../../timing"
import dsv "../../../../dsv"
import json "../../../../json"

// Keeps a read lane's work from folding away.
sink: u64

// What a lane read, folded by timing.fnv.
check: u64

// The key lane's tally, printed beside its checksum for the other arms' key lanes.
key_answers, key_objects: u64
key_name: string
key_name_buf: [128]u8

// The handle of a file that is neither JSON nor dsv, which is read through `core`.
generic: bool
handle: core.As

Arena :: struct {
	arena: mem.Arena,
	alloc: mem.Allocator,
}

// The build lane's check: the node count, then each node's kind tag and role in document order.
document_check :: proc(doc: ^core.Document) -> u64 {
	h := timing.fnv_u64(timing.CHECK_OFFSET, u64(len(doc.nodes)))
	for n in doc.nodes {
		h = timing.fnv(h, formats.value_tag(n.kind))
		h = timing.fnv(h, u8(n.role))
	}
	return h
}

// `document_check` with each node's kind as its format resolves it, so a YAML plain scalar counts as the string, number,
// boolean or null it reads as.
resolved_check :: proc(doc: ^core.Document) -> u64 {
	h := timing.fnv_u64(timing.CHECK_OFFSET, u64(len(doc.nodes)))
	for n, i in doc.nodes {
		h = timing.fnv(h, formats.value_tag(core.kind(doc, core.Node_Index(i))))
		h = timing.fnv(h, u8(n.role))
	}
	return h
}

// Each lane is its own out-of-line procedure so one lane's body cannot change another lane's register allocation
// in a probe that runs exactly one of them. Inlining them into the dispatcher puts every lane in one frame.
run_lane :: proc(a: ^Arena, lane: string, src: []u8, tsv: bool, dsv_text: bool, spec: json.Spec) -> i64 {
	times: [timing.TIMED]i64
	for i in 0 ..< timing.WARMUP + timing.TIMED {
		a.arena.offset = 0
		start := time.tick_now()
		switch lane {
		case "build":
			lane_build(a, src, tsv, dsv_text, spec)
		case "read":
			lane_read(a, src, tsv, dsv_text, spec)
		case "key":
			lane_key(a, src, tsv, dsv_text, spec)
		case "infer":
			lane_infer(a, src, tsv, dsv_text, spec)
		case "validate":
			lane_validate(src)
		case:
			fmt.eprintln("lane: build, read, key, infer or validate")
			os.exit(2)
		}
		d := i64(time.tick_since(start))
		if i >= timing.WARMUP {
			times[i - timing.WARMUP] = d
		}
	}
	return timing.median(&times)
}

// Judges the text and builds nothing. Its check is 1 for a text the format accepts.
lane_validate :: #force_no_inline proc(src: []u8) {
	if err := core.validate(src, handle); err != nil {
		core.render(os.to_writer(os.stderr), src, err)
		fmt.eprintln()
		os.exit(1)
	}
	check = 1
}

lane_build :: #force_no_inline proc(a: ^Arena, src: []u8, tsv, dsv_text: bool, spec: json.Spec) {
	_ = build(a, src, tsv, dsv_text, spec)
}

// A dsv text built with `infer`, which stores each cell's kind. A text of another format builds as `build` does.
lane_infer :: #force_no_inline proc(a: ^Arena, src: []u8, tsv, dsv_text: bool, spec: json.Spec) {
	_ = build(a, src, tsv, dsv_text, spec, true)
}

lane_read :: #force_no_inline proc(a: ^Arena, src: []u8, tsv, dsv_text: bool, spec: json.Spec) {
	read_all(a, src, tsv, dsv_text, spec, false)
}

lane_key :: #force_no_inline proc(a: ^Arena, src: []u8, tsv, dsv_text: bool, spec: json.Spec) {
	key_lookup(a, src, tsv, dsv_text, spec)
}

build :: proc(a: ^Arena, src: []u8, tsv, dsv_text: bool, spec: json.Spec, infer := false) -> core.Document {
	doc: core.Document
	err: core.Error
	if generic {
		doc, err = core.build(src, handle, .Last, a.alloc)
	} else if dsv_text {
		if tsv {
			doc, err = dsv.build(src, .Tsv, {infer = infer}, .Last, a.alloc)
		} else {
			doc, err = dsv.build(src, .Csv, {infer = infer}, .Last, a.alloc)
		}
	} else {
		switch spec {
		case .Json:
			doc, err = json.build(src, .Json, {}, .Last, a.alloc)
		case .Jsonc:
			doc, err = json.build(src, .Jsonc, {}, .Last, a.alloc)
		case .Json5:
			doc, err = json.build(src, .Json5, {}, .Last, a.alloc)
		}
	}
	if err != nil {
		core.render(os.to_writer(os.stderr), src, err)
		fmt.eprintln()
		os.exit(1)
	}
	return doc
}

// Values only: foundations' `dom_read` reads one row per value, and a key is no row there, so the same work here
// leaves keys to the `key` lane. `HASH` false is the timed read, which folds each value into `sink`. `HASH` true is
// the untimed check, which counts each value's tag, then its decoded text length or its number bits, in document
// order.
read_all :: proc(a: ^Arena, src: []u8, tsv, dsv_text: bool, spec: json.Spec, $HASH: bool) {
	doc := build(a, src, tsv, dsv_text, spec)
	buf: [4096]u8
	when HASH {
		check = timing.CHECK_OFFSET
	}
	if generic {
		if read_nodes(a, &doc, buf[:], false, HASH, false, true) {
			when HASH {
				check = timing.CHECK_OFFSET
			}
			read_nodes(a, &doc, buf[:], false, HASH, true, true)
		}
	} else if !dsv_text && spec == .Json {
		if read_nodes(a, &doc, buf[:], true, HASH, false, false) {
			when HASH {
				check = timing.CHECK_OFFSET
			}
			read_nodes(a, &doc, buf[:], true, HASH, true, false)
		}
	} else {
		if read_nodes(a, &doc, buf[:], false, HASH, false, false) {
			when HASH {
				check = timing.CHECK_OFFSET
			}
			read_nodes(a, &doc, buf[:], false, HASH, true, false)
		}
	}
}

// `DIRECT` picks the format's own readers, which inline for a caller that knows the format, or the format-agnostic
// `core` readers, as dsv cells need. `RESOLVE` takes each node as the kind its format resolves it to, which a YAML plain
// scalar or an XML text needs and a JSON or dsv text does not.
// Reads every value. `FALLBACK` false is the fast lane, which stops and returns true at the first text too long for
// `buf`. `FALLBACK` true is the slow lane, which clones such a text and frees it. A document whose texts all fit pays
// for one lane only, and a text that does not fit is read by the slow lane from the start.
read_nodes :: proc(a: ^Arena, doc: ^core.Document, buf: []u8, $DIRECT: bool, $HASH: bool, $FALLBACK: bool, $RESOLVE: bool) -> (long: bool) {
	for n, i in doc.nodes {
		if n.role != .Value {
			continue
		}
		kind := n.kind
		when RESOLVE {
			kind = core.kind(doc, core.Node_Index(i))
		}
		when HASH {
			check = timing.fnv(check, formats.value_tag(kind))
		}
		if kind == .String || kind == .Plain || (RESOLVE && kind == .Bytes) {
			text_ok: bool
			size := 0
			when DIRECT {
				s, ok := json.token_text(&doc.view, n, buf)
				text_ok = ok
				size = len(s)
			} else {
				s, ok := core.text(doc, core.Node_Index(i), buf)
				text_ok = ok
				size = len(s)
			}
			if !text_ok {
				when FALLBACK {
					size, text_ok = long_text_length(doc, core.Node_Index(i), a.alloc)
					if !text_ok {
						fmt.eprintf("read: text of node %d failed\n", i)
						os.exit(1)
					}
				} else {
					return true
				}
			}
			when HASH {
				check = timing.fnv_u64(check, u64(size))
			} else {
				sink = sink ~ u64(size)
			}
			continue
		}
		if kind == .Number {
			num: core.Number
			when DIRECT {
				num, _ = json.token_number(&doc.view, doc.nodes[i])
			} else {
				num, _ = core.number(doc, core.Node_Index(i))
			}
			when HASH {
				check = timing.fnv_u64(check, formats.number_bits(num))
			} else {
				sink = sink ~ num.bits ~ u64(num.kind)
			}
		}
	}
	return false
}

// Returns a name read through the format's direct reader or core's, and whether the read cloned it. A name too long for
// `buf` is cloned, and the caller frees it with `alloc`.
@(private)
read_name :: #force_no_inline proc(doc: ^core.Document, i: core.Node_Index, buf: []u8, alloc: mem.Allocator, direct: bool) -> (name: string, cloned: bool, ok: bool) {
	if direct {
		name, ok = json.token_text(&doc.view, doc.nodes[i], buf)
	} else {
		name, ok = core.text(doc, i, buf)
	}
	if ok {
		return name, false, true
	}
	name, ok = core.text_clone(doc, i, alloc)
	return name, true, ok
}

// Returns a text too long for the read lane's buffer, and frees it before returning. A read with a stack buffer covers
// every text that fits, so only a long one pays for the clone.
@(private, cold)
long_text_length :: #force_no_inline proc(doc: ^core.Document, i: core.Node_Index, alloc: mem.Allocator) -> (n: int, ok: bool) {
	s, read := core.text_clone(doc, i, alloc)
	if !read {
		return 0, false
	}
	n = len(s)
	delete(s, alloc)
	return n, true
}

// A member lookup that knows the format: each member's key goes through `core.key_equals` directly, with `.First`
// reading as `core.member` does.
json_member :: proc(doc: ^core.Document, obj: core.Node_Index, name: string) -> (core.Node_Index, bool) {
	it := core.children(doc, obj)
	for {
		v, ok := core.child_next(&it)
		if !ok {
			return core.NO_NODE, false
		}
		if core.key_equals(doc, v - 1, name) {
			return v, true
		}
	}
}

key_lookup :: proc(a: ^Arena, src: []u8, tsv, dsv_text: bool, spec: json.Spec) {
	doc := build(a, src, tsv, dsv_text, spec)
	buf: [4096]u8
	inline := !generic && !dsv_text && spec == .Json
	name: string
	found := false
	key_answers = 0
	key_objects = 0
	key_name = ""
	name_cloned := false
	defer if name_cloned {
		delete(name, a.alloc)
	}
	check = timing.CHECK_OFFSET
	if dsv_text {
		// A headed dsv text's header row is the root's first child, an `Array` of role `Key` whose first cell names
		// its first column.
		for n, i in doc.nodes {
			if n.kind == .Array && n.role == .Key && int(i) + 1 < len(doc.nodes) {
				text_ok: bool
				name, name_cloned, text_ok = read_name(&doc, core.Node_Index(i) + 1, buf[:], a.alloc, false)
				if !text_ok {
					fmt.eprintf("key: header cell %d failed\n", i + 1)
					os.exit(1)
				}
				found = true
				break
			}
		}
	} else {
		for n, i in doc.nodes {
			if n.kind != .Object {
				continue
			}
			j := i + 1
			if j < len(doc.nodes) && doc.nodes[j].role == .Key {
				text_ok: bool
				name, name_cloned, text_ok = read_name(&doc, core.Node_Index(j), buf[:], a.alloc, inline)
				if !text_ok {
					fmt.eprintf("key: node %d's key failed\n", i)
					os.exit(1)
				}
				found = true
			}
			break
		}
	}
	if !found {
		check = timing.fnv_u64(timing.fnv_u64(check, 0), 0)
		return
	}
	if len(name) <= len(key_name_buf) {
		copy(key_name_buf[:], name)
		key_name = string(key_name_buf[:len(name)])
	}
	check = timing.fnv_bytes(check, transmute([]u8)name)
	if dsv_text {
		// The column is resolved once: `member` on the first record names its cell, whose offset in its record is
		// the column every record's cell sits at, so each record costs one indexed read.
		first := core.NO_NODE
		for n, i in doc.nodes {
			if (n.kind == .Object || n.kind == .Array) && n.role == .Value && i != 0 {
				first = core.Node_Index(i)
				break
			}
		}
		col := -1
		if first != core.NO_NODE {
			if cell, ok := core.member(&doc, first, name, .First); ok {
				col = int(cell - first - 1)
			}
		}
		for n, i in doc.nodes {
			if (n.kind == .Object || n.kind == .Array) && n.role == .Value && i != 0 {
				key_objects += 1
				hit := false
				if col >= 0 {
					if cell, ok := core.child_at(&doc, core.Node_Index(i), col); ok {
						sink = sink ~ u64(cell)
						hit = true
					}
				} else {
					if cell, ok := core.member(&doc, core.Node_Index(i), name, .First); ok {
						sink = sink ~ u64(cell)
						hit = true
					}
				}
				if hit {
					key_answers += 1
				}
			}
		}
	} else {
		for n, i in doc.nodes {
			if n.kind == .Object {
				key_objects += 1
				if inline {
					if f, ok := json_member(&doc, core.Node_Index(i), name); ok {
						sink = sink ~ u64(f)
						key_answers += 1
					}
				} else {
					if f, ok := core.member(&doc, core.Node_Index(i), name, .First); ok {
						sink = sink ~ u64(f)
						key_answers += 1
					}
				}
			}
		}
	}
	sink = sink ~ u64(len(name))
	check = timing.fnv_u64(timing.fnv_u64(check, key_answers), key_objects)
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: doc <build|read|key|validate> <file>")
		os.exit(2)
	}
	src, err := os.read_entire_file_from_path(os.args[2], context.allocator)
	if err != nil {
		fmt.eprintln("read:", err)
		os.exit(1)
	}
	defer delete(src)

	// A JSON build reserves half the source bytes in nodes (8 bytes per source byte), so nested.json's 16 MiB
	// needs 128 MiB and the rest of the probe's allocations ride above it. The backing is non-zeroed, so only
	// the pages a lane touches count toward the probe's RSS.
	backing, aerr := mem.alloc_bytes_non_zeroed(512 << 20)
	if aerr != nil {
		fmt.eprintln("arena backing:", aerr)
		os.exit(1)
	}
	defer delete(backing)
	a: Arena
	mem.arena_init(&a.arena, backing)
	a.alloc = mem.arena_allocator(&a.arena)

	path := os.args[2]
	dsv_text := strings.has_suffix(path, ".csv") || strings.has_suffix(path, ".tsv")
	tsv := strings.has_suffix(path, ".tsv")
	spec := json.Spec.Json
	if strings.has_suffix(path, ".jsonc") {
		spec = .Jsonc
	} else if strings.has_suffix(path, ".json5") {
		spec = .Json5
	}
	if kind := formats.of_path(path); kind >= .Yaml {
		generic = true
		handle = formats.handle(kind)
	}
	ns := run_lane(&a, os.args[1], src, tsv, dsv_text, spec)
	if ns <= 0 {
		ns = 1
	}
	// The checksum is one untimed call over a fresh document, so the timed lanes carry no hash chain.
	switch os.args[1] {
	case "build":
		a.arena.offset = 0
		doc := build(&a, src, tsv, dsv_text, spec)
		check = resolved_check(&doc) if generic else document_check(&doc)
	case "read":
		a.arena.offset = 0
		read_all(&a, src, tsv, dsv_text, spec, true)
	}
	if os.args[1] == "key" {
		fmt.printfln(
			"gb_per_s=%.3f ns=%d check=%d answers=%d objects=%d key=%s",
			f64(len(src)) / f64(ns),
			ns,
			check,
			key_answers,
			key_objects,
			key_name,
		)
	} else {
		fmt.printfln("gb_per_s=%.3f ns=%d check=%d", f64(len(src)) / f64(ns), ns, check)
	}
}
