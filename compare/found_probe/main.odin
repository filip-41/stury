// The old tree's (`core`, `json`, `csv`) document lanes doing what `next/bench/doc` does: one build, a read of every
// value with next's checksum, and one key from the first object (or header cell) looked up in every object (or
// record) with one column resolve per sample. Both arms use a 512 MiB arena reset per call, two warm-ups and ten
// timed calls.
//
// Some differences remain by construction. The old build decodes escapes and cells at build time, next decodes text
// at read time. The two builds reserve nodes by different rules. A dsv record is an `Object` in this tree and an
// `Array` in next, and an empty cell is `Null` here and an empty `Plain` cell there, so the checksum maps each to
// next's tag. The build checksum is next's document summary, written for the nodes next has: a JSON key and a dsv
// header row are no rows here.
//
// `probe <build|read|key> <file>` prints key=value tokens. Exits 2 on a usage error, 1 on a document fault.
package main

import csv "stury:csv"
import core "stury:core"
import json "stury:json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:time"

// Keeps a read lane's work from folding away.
sink: u64

CHECK_OFFSET :: u64(14695981039346656037)
CHECK_PRIME :: u64(1099511628211)
check: u64

key_answers, key_objects: u64
key_name: string
key_name_buf: [128]u8

Arena :: struct {
	arena: mem.Arena,
	alloc: mem.Allocator,
}

fnv :: #force_inline proc(h0: u64, b: u8) -> u64 {
	h := h0
	return (h ~ u64(b)) * CHECK_PRIME
}

fnv_bytes :: proc(h0: u64, bytes: []u8) -> u64 {
	h := h0
	for b in bytes {
		h = fnv(h, b)
	}
	return h
}

fnv_u64 :: proc(h0: u64, v: u64) -> u64 {
	h := h0
	for i in 0 ..< 8 {
		h = fnv(h, u8(v >> uint(8 * i)))
	}
	return h
}

// The byte next's visitor adds for a value of `k`. A dsv record is an `Object` in this tree and an `Array` in next's
// document, so both tag `a` there. An empty cell is `Null` here and an empty `Plain` cell there, so both tag `s`.
value_tag :: #force_inline proc(k: core.Kind, dsv_text: bool) -> u8 {
	switch k {
	case .Object:
		return 'a' if dsv_text else 'o'
	case .Array:
		return 'a'
	case .String:
		return 's'
	case .Number:
		return 'n'
	case .True:
		return 't'
	case .False:
		return 'f'
	case .Null:
		return 's' if dsv_text else 'z'
	}
	return 0
}

run_lane :: proc(a: ^Arena, lane: string, src: []byte, tsv: bool, dsv_text: bool) -> i64 {
	times: [10]i64
	for i in 0 ..< 12 {
		a.arena.offset = 0
		start := time.tick_now()
		switch lane {
		case "build":
			lane_build(a, src, tsv, dsv_text)
		case "read":
			lane_read(a, src, tsv, dsv_text)
		case "key":
			lane_key(a, src, tsv, dsv_text)
		case:
			fmt.eprintln("lane: build, read or key")
			os.exit(2)
		}
		d := i64(time.tick_since(start))
		if i >= 2 {
			times[i - 2] = d
		}
	}
	slice.sort(times[:])
	return (times[4] + times[5]) / 2
}

lane_build :: #force_no_inline proc(a: ^Arena, src: []byte, tsv, dsv_text: bool) {
	_ = build(a, src, tsv, dsv_text)
}

lane_read :: #force_no_inline proc(a: ^Arena, src: []byte, tsv, dsv_text: bool) {
	read_all(a, src, tsv, dsv_text, false)
}

lane_key :: #force_no_inline proc(a: ^Arena, src: []byte, tsv, dsv_text: bool) {
	key_lookup(a, src, tsv, dsv_text)
}

build :: proc(a: ^Arena, src: []byte, tsv, dsv_text: bool) -> core.Document {
	doc: core.Document
	err: Maybe(json.Error)
	if dsv_text {
		dialect := csv.TSV if tsv else csv.Dialect{}
		doc, err = csv.build(src, {dialect = dialect}, a.alloc)
	} else {
		doc, err = json.build(src, {}, a.alloc)
	}
	if err != nil {
		fmt.eprintln("document error:", err)
		os.exit(1)
	}
	return doc
}

// The binary64 bits of a number's value, the form every arm's reader holds. Zero folds as +0, since next's reader
// keeps no sign on it.
number_bits :: proc(doc: ^core.Document, n: core.Node) -> u64 {
	num, ok := json.get_number(doc, n)
	if !ok {
		fmt.eprintln("read: number read failed")
		os.exit(1)
	}
	if num.value == 0 {
		return 0
	}
	return transmute(u64)num.value
}

// `HASH` false is the timed read, which folds each value into `sink`. `HASH` true is the untimed check, which counts
// each value's tag, then its decoded text length or its number bits, in document order.
read_all :: proc(a: ^Arena, src: []byte, tsv, dsv_text: bool, $HASH: bool) {
	doc := build(a, src, tsv, dsv_text)
	when HASH {
		check = CHECK_OFFSET
	}
	for i in 0 ..< len(doc.rows) {
		n := core.Node(i)
		kd, ok := json.kind(&doc, n)
		if !ok {
			fmt.eprintln("read: kind read failed")
			os.exit(1)
		}
		when HASH {
			check = fnv(check, value_tag(kd, dsv_text))
		}
		switch kd {
		case .String:
			s, sok := json.get_string(&doc, n)
			if !sok {
				fmt.eprintln("read: string read failed")
				os.exit(1)
			}
			when HASH {
				check = fnv_u64(check, u64(len(s)))
			} else {
				sink = sink ~ u64(len(s))
			}
		case .Number:
			when HASH {
				check = fnv_u64(check, number_bits(&doc, n))
			} else {
				num, _ := json.get_number(&doc, n)
				sink = sink ~ transmute(u64)num.value
			}
		case .Object, .Array, .True, .False, .Null:
		}
	}
}

// The build lane's check, in next's document shape: the node count, then each node's kind tag and role in document
// order. A JSON key is a span here and a node in next, so `json_nodes` writes one where next does.
document_check :: proc(doc: ^core.Document, dsv_text: bool) -> u64 {
	h: u64
	if dsv_text {
		rows := csv.child_count(doc, csv.ROOT)
		columns := 0
		if first := csv.child(doc, csv.ROOT, 0); first != core.NO_NODE {
			columns = csv.child_count(doc, first)
		}
		h = fnv_u64(CHECK_OFFSET, u64(2 + columns + rows * (1 + columns)))
		// The root, the header row and its cells.
		h = fnv(h, 'a')
		h = fnv(h, 0)
		h = fnv(h, 'a')
		h = fnv(h, 1)
		for _ in 0 ..< columns {
			h = fnv(h, 's')
			h = fnv(h, 1)
		}
		records := csv.children(doc, csv.ROOT)
		for {
			rec, more := csv.children(&records)
			if !more {
				break
			}
			h = fnv(h, 'a')
			h = fnv(h, 0)
			cells := csv.children(doc, rec)
			for {
				cell, cell_more := csv.children(&cells)
				if !cell_more {
					break
				}
				kd, _ := csv.kind(doc, cell)
				h = fnv(h, value_tag(kd, true))
				h = fnv(h, 0)
			}
		}
		return h
	}
	count := len(doc.rows)
	for i in 0 ..< len(doc.rows) {
		if kd, _ := json.kind(doc, core.Node(i)); kd == .Object {
			count += json.child_count(doc, core.Node(i))
		}
	}
	h = fnv_u64(CHECK_OFFSET, u64(count))
	json_nodes(doc, json.ROOT, &h)
	return h
}

json_nodes :: proc(doc: ^core.Document, n: core.Node, h: ^u64) {
	kd, ok := json.kind(doc, n)
	if !ok {
		fmt.eprintln("summary: kind read failed")
		os.exit(1)
	}
	h^ = fnv(h^, value_tag(kd, false))
	h^ = fnv(h^, 0)
	switch kd {
	case .Object:
		it := json.members(doc, n)
		for {
			_, val, has := json.members(&it)
			if !has {
				break
			}
			h^ = fnv(h^, 's')
			h^ = fnv(h^, 1)
			json_nodes(doc, val, h)
		}
	case .Array:
		it := json.children(doc, n)
		for {
			val, has := json.children(&it)
			if !has {
				break
			}
			json_nodes(doc, val, h)
		}
	case .String, .Number, .True, .False, .Null:
	}
}

key_lookup :: proc(a: ^Arena, src: []byte, tsv, dsv_text: bool) {
	doc := build(a, src, tsv, dsv_text)
	name: string
	found := false
	key_answers = 0
	key_objects = 0
	key_name = ""
	check = CHECK_OFFSET
	if dsv_text {
		first := csv.child(&doc, csv.ROOT, 0)
		if first != core.NO_NODE {
			it := csv.members(&doc, first)
			if key, _, has := csv.members(&it); has {
				name, found = key, true
			}
		}
	} else {
		for i in 0 ..< len(doc.rows) {
			n := core.Node(i)
			kd, ok := json.kind(&doc, n)
			if !ok {
				break
			}
			if kd != .Object {
				continue
			}
			it := json.members(&doc, n)
			if key, _, has := json.members(&it); has {
				name, found = key, true
			}
			break
		}
	}
	if !found {
		check = fnv_u64(fnv_u64(check, 0), 0)
		return
	}
	if len(name) <= len(key_name_buf) {
		copy(key_name_buf[:], name)
		key_name = string(key_name_buf[:len(name)])
	}
	check = fnv_bytes(check, transmute([]u8)name)
	if dsv_text {
		first := csv.child(&doc, csv.ROOT, 0)
		col := -1
		if first != core.NO_NODE {
			if cell := csv.child(&doc, first, name); cell != core.NO_NODE {
				col = int(cell - first - 1)
			}
		}
		// Next's lane scans the flat node array for record containers, so scan the rows the same way.
		for i in 0 ..< len(doc.rows) {
			rec := core.Node(i)
			kd, ok := csv.kind(&doc, rec)
			if !ok {
				break
			}
			if kd != .Object || i == 0 {
				continue
			}
			key_objects += 1
			hit := false
			if col >= 0 {
				if cell := csv.child(&doc, rec, col); cell != core.NO_NODE {
					sink = sink ~ u64(cell)
					hit = true
				}
			}
			if hit {
				key_answers += 1
			}
		}
	} else {
		for i in 0 ..< len(doc.rows) {
			n := core.Node(i)
			kd, ok := json.kind(&doc, n)
			if !ok {
				break
			}
			if kd != .Object {
				continue
			}
			key_objects += 1
			if f := json.child(&doc, n, name); f != core.NO_NODE {
				sink = sink ~ u64(f)
				key_answers += 1
			}
		}
	}
	sink = sink ~ u64(len(name))
	check = fnv_u64(fnv_u64(check, key_answers), key_objects)
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: probe <build|read|key> <file>")
		os.exit(2)
	}
	src, err := os.read_entire_file_from_path(os.args[2], context.allocator)
	if err != nil {
		fmt.eprintln("read:", err)
		os.exit(1)
	}
	defer delete(src)

	backing := make([]byte, 512 << 20)
	defer delete(backing)
	a: Arena
	mem.arena_init(&a.arena, backing)
	a.alloc = mem.arena_allocator(&a.arena)

	path := os.args[2]
	dsv_text := has_suffix(path, ".csv") || has_suffix(path, ".tsv")
	tsv := has_suffix(path, ".tsv")
	ns := run_lane(&a, os.args[1], src, tsv, dsv_text)
	if ns <= 0 {
		ns = 1
	}
	// The checksum is one untimed call over a fresh document, so the timed lanes carry no hash chain.
	switch os.args[1] {
	case "build":
		a.arena.offset = 0
		doc := build(&a, src, tsv, dsv_text)
		check = document_check(&doc, dsv_text)
	case "read":
		a.arena.offset = 0
		read_all(&a, src, tsv, dsv_text, true)
	case "key":
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

has_suffix :: proc(s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}
