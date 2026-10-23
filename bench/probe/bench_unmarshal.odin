package main

// Unmarshal lanes. Every lane reports input bytes per second. The tape arm is the
// baseline the walk is held to: on logs and nested, `build` the node tape, then one pass per record that
// predicts the next name the way `unmarshal` does, so the comparison is walk against tape and not matcher
// against matcher; on logs_subset and config, which read a few fields, a `.Path` scan of those fields.

import "base:intrinsics"
import json "stury:json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:time"

// One static arena holds every read of an arena lane: a reset faults no pages in, and a read past the reserve
// fails the lane instead of growing a block that each reset would free. The `Unmarshal` arm does not use it
// for the timed reads; it reads from `context.allocator` as the other libraries' decoders read from malloc.
READ_ARENA_RESERVE :: 1 << 30

Read_Arm :: enum {
	// `unmarshal` into `context.allocator`; the previous value is freed outside the clock.
	Unmarshal,
	// `unmarshal` into a warm arena reset outside the clock.
	Unmarshal_Arena,
	Tape,
	Check,
}

Logs_Doc :: struct {
	logs: []Log_Record,
}

Log_Subset :: struct {
	status: i64,
	id:     string,
}

Logs_Subset_Doc :: struct {
	logs: []Log_Subset,
}

Nested_B :: struct {
	c: i64,
}

Nested_Inner :: struct {
	a: []f64,
	b: Nested_B,
}

Nested_Rec :: struct {
	id:     i64,
	name:   string,
	tags:   []i64,
	nested: Nested_Inner,
	ok:     bool,
}

Config_Head :: struct {
	name: string,
	port: i64,
}

// `arm`'s read of `data` as a `T`, one per timed iteration with a kept plan: into a reset arena (`Unmarshal_Arena`,
// `Tape`), or from `context.allocator` with `release` freeing the last value after the clock (`Unmarshal`). Before
// timing, `unmarshal` and `tape` each read once and must marshal to the same bytes, so both arms do one job;
// `unmarshal_check` must refuse what `unmarshal` refuses for `.Check`.
bench_read :: proc(
	data: []byte,
	$T: typeid,
	arm: Read_Arm,
	opts: json.Unmarshal_Opts,
	tape: proc(data: []byte, out: ^T, a: mem.Allocator) -> bool,
	records: proc(v: ^T) -> int,
	release: proc(v: ^T),
) -> bool {
	arena: virtual.Arena
	if virtual.arena_init_static(&arena, READ_ARENA_RESERVE) != nil {
		return false
	}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	plan := json.type_plan_init(T)
	defer json.destroy(&plan)

	walked, taped: T
	if json.unmarshal(data, &walked, opts, &plan, a) != nil || !tape(data, &taped, a) {
		return false
	}
	walk_bytes, werr := json.marshal(walked, allocator = a)
	tape_bytes, terr := json.marshal(taped, allocator = a)
	if werr != .None || terr != .None || string(walk_bytes) != string(tape_bytes) {
		return false
	}
	// The value read, for bench/compare.py to hold every other library's typed read against.
	if path, found := os.lookup_env("STURY_DUMP", a); found && os.write_entire_file(path, walk_bytes) != nil {
		return false
	}
	if arm == .Check {
		// A string root, which every lane's type refuses.
		bad := transmute([]byte)string(`"x"`)
		refused: T
		want, refused_ok := json.unmarshal(bad, &refused, opts, &plan, a).?
		got, _ := json.unmarshal_check(bad, T, opts, &plan).?
		if !refused_ok || got.kind != want.kind || json.unmarshal_check(data, T, opts, &plan) != nil {
			return false
		}
	}
	n := records(&walked)

	times: [TIMED_ITERS]i64
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		virtual.arena_free_all(&arena)
		out: T
		ok: bool
		t := time.tick_now()
		switch arm {
		case .Unmarshal:
			ok = json.unmarshal(data, &out, opts, &plan) == nil
		case .Unmarshal_Arena:
			ok = json.unmarshal(data, &out, opts, &plan, a) == nil
		case .Tape:
			ok = tape(data, &out, a)
		case .Check:
			ok = json.unmarshal_check(data, T, opts, &plan) == nil
		}
		d := i64(time.tick_since(t))
		if arm == .Unmarshal {
			release(&out)
		}
		if !ok {
			return false
		}
		keep_timed(&times, i, d)
	}
	fmt.printf("gb_per_s=%.4g records=%d rss_bytes=%d\n", f64(len(data)) / f64(median(times)), n, rss_growth(RSS_MARK))
	return true
}

STRICT_READ :: json.Unmarshal_Opts{strictness = .Strict, borrow_strings = true}
LAZY_READ :: json.Unmarshal_Opts{strictness = .Lazy, borrow_strings = true}

bench_unmarshal_logs :: proc(data: []byte, arm: Read_Arm) -> bool {
	return bench_read(data, Logs_Doc, arm, STRICT_READ, tape_logs, proc(v: ^Logs_Doc) -> int {return len(v.logs)}, proc(v: ^Logs_Doc) {delete(v.logs)})
}

bench_unmarshal_logs_subset :: proc(data: []byte, arm: Read_Arm, opts: json.Unmarshal_Opts) -> bool {
	return bench_read(data, Logs_Subset_Doc, arm, opts, tape_logs_subset, proc(v: ^Logs_Subset_Doc) -> int {return len(v.logs)}, proc(v: ^Logs_Subset_Doc) {delete(v.logs)})
}

bench_unmarshal_nested :: proc(data: []byte, arm: Read_Arm) -> bool {
	return bench_read(data, []Nested_Rec, arm, STRICT_READ, tape_nested, proc(v: ^[]Nested_Rec) -> int {return len(v^)}, release_nested)
}

bench_unmarshal_config :: proc(data: []byte, arm: Read_Arm, opts: json.Unmarshal_Opts) -> bool {
	return bench_read(data, Config_Head, arm, opts, tape_config, proc(_: ^Config_Head) -> int {return 1}, proc(_: ^Config_Head) {})
}

// Frees what an `unmarshal` of `[]Nested_Rec` made. The strings are borrowed from the input: the fixture has no escapes.
release_nested :: proc(v: ^[]Nested_Rec) {
	for &r in v^ {
		delete(r.tags)
		delete(r.nested.a)
	}
	delete(v^)
}

// A record's field names, and bit b of `first` set when one starts with byte b, as `unmarshal` keeps them.
Tape_Names :: struct {
	names: []string,
	first: [4]u64,
}

tape_names :: proc(names: []string) -> (t: Tape_Names) {
	t.names = names
	for name in names {
		b := name[0] if len(name) > 0 else 0
		t.first[b >> 6] |= u64(1) << (b & 63)
	}
	return
}

// Member `c`'s key, decoded into the document's arena when it is escaped.
tape_key :: #force_inline proc(doc: ^json.Document, c: json.Node) -> (key: string, ok: bool) {
	r := doc.rows[c]
	if .Key_Escaped in r.flags {
		return json.get_key(doc, c)
	}
	return string(doc.src[r.key_lo + 1:r.key_hi - 1]), true
}

// One pass over a record's members: the predicted name first, then the rest, past a first-byte filter.
// Returns the field index or -1.
tape_field :: #force_inline proc(doc: ^json.Document, c: json.Node, t: ^Tape_Names, next: ^int) -> int {
	key, ok := tape_key(doc, c)
	if !ok {
		return -1
	}
	if next^ < len(t.names) && t.names[next^] == key {
		next^ += 1
		return next^ - 1
	}
	b := key[0] if len(key) > 0 else 0
	if t.first[b >> 6] & (u64(1) << (b & 63)) == 0 {
		return -1
	}
	for name, i in t.names {
		if name == key {
			next^ = i + 1
			return i
		}
	}
	return -1
}

// The array of records under the root object's member `name` (the last one), or false.
tape_records :: proc(doc: ^json.Document, name: string) -> (json.Node, bool) {
	if kd, _ := json.kind(doc, 0); kd != .Object {
		return json.NO_NODE, false
	}
	found := json.NO_NODE
	c_it := json.children(doc, 0)
	for c in json.children(&c_it) {
		if key, ok := tape_key(doc, c); ok && key == name {
			found = c
		}
	}
	kd, _ := json.kind(doc, found)
	return found, found != json.NO_NODE && kd == .Array
}

LOG_NAMES :: [?]string{"ts", "level", "service", "msg", "status", "bytes", "duration_ms", "id"}

tape_logs :: proc(data: []byte, out: ^Logs_Doc, a: mem.Allocator) -> bool {
	doc, berr := json.build(data, a)
	if berr != nil {
		return false
	}
	logs := tape_records(&doc, "logs") or_return
	names := LOG_NAMES
	t := tape_names(names[:])
	out.logs = make([]Log_Record, json.child_count(&doc, logs), a)
	k := 0
	rec_it := json.children(&doc, logs)
	for rec in json.children(&rec_it) {
		if kd, _ := json.kind(&doc, rec); kd != .Object {
			return false
		}
		o := &out.logs[k]
		k += 1
		seen: u8
		next := 0
		c_it := json.children(&doc, rec)
		for c in json.children(&c_it) {
			switch tape_field(&doc, c, &t, &next) {
			case 0: o.ts = json.get_string(&doc, c) or_return
			case 1: o.level = json.get_string(&doc, c) or_return
			case 2: o.service = json.get_string(&doc, c) or_return
			case 3: o.msg = json.get_string(&doc, c) or_return
			case 4: o.status = tape_int(&doc, c) or_return
			case 5: o.bytes = tape_int(&doc, c) or_return
			case 6: o.duration_ms = tape_float(&doc, c) or_return
			case 7: o.id = json.get_string(&doc, c) or_return
			case: continue
			}
			seen |= 1 << uint(next - 1)
		}
		if seen != 0xFF {
			return false
		}
	}
	return true
}

tape_logs_subset :: proc(data: []byte, out: ^Logs_Subset_Doc, a: mem.Allocator) -> bool {
	paths := [2]json.Path{
		{steps = []json.Step{json.Name("logs"), json.Any{}, json.Name("status")}},
		{steps = []json.Step{json.Name("logs"), json.Any{}, json.Name("id")}},
	}
	req := json.Request({.Path}){paths = paths[:], strictness = .Strict, allocator = a}
	if json.scan(data, &req) != nil {
		return false
	}
	status, status_err := json.answers(&req, 0)
	id, id_err := json.answers(&req, 1)
	if status_err != nil || id_err != nil || len(status) != len(id) {
		return false
	}
	out.logs = make([]Log_Subset, len(status), a)
	for &o, k in out.logs {
		if status[k].owner != id[k].owner {
			return false
		}
		o.status = span_int(data, status[k]) or_return
		o.id = span_string(data, id[k], a) or_return
	}
	return true
}

NESTED_NAMES :: [?]string{"id", "name", "tags", "nested", "ok"}
NESTED_INNER_NAMES :: [?]string{"a", "b"}
NESTED_B_NAMES :: [?]string{"c"}

tape_nested :: proc(data: []byte, out: ^[]Nested_Rec, a: mem.Allocator) -> bool {
	doc, berr := json.build(data, a)
	root_kind, _ := json.kind(&doc, 0)
	if berr != nil || root_kind != .Array {
		return false
	}
	names, inner_names, b_names := NESTED_NAMES, NESTED_INNER_NAMES, NESTED_B_NAMES
	t, inner, bt := tape_names(names[:]), tape_names(inner_names[:]), tape_names(b_names[:])
	out^ = make([]Nested_Rec, json.child_count(&doc, 0), a)
	k := 0
	rec_it := json.children(&doc, 0)
	for rec in json.children(&rec_it) {
		if kd, _ := json.kind(&doc, rec); kd != .Object {
			return false
		}
		o := &out[k]
		k += 1
		seen: u8
		next := 0
		c_it := json.children(&doc, rec)
		for c in json.children(&c_it) {
			switch tape_field(&doc, c, &t, &next) {
			case 0: o.id = tape_int(&doc, c) or_return
			case 1: o.name = json.get_string(&doc, c) or_return
			case 2: o.tags = tape_ints(&doc, c, a) or_return
			case 3: tape_nested_inner(&doc, c, &inner, &bt, &o.nested, a) or_return
			case 4:
				kd, _ := json.kind(&doc, c)
				if kd != .True && kd != .False {
					return false
				}
				o.ok = kd == .True
			case: continue
			}
			seen |= 1 << uint(next - 1)
		}
		if seen != 0b11111 {
			return false
		}
	}
	return true
}

tape_nested_inner :: proc(doc: ^json.Document, obj: json.Node, t, bt: ^Tape_Names, o: ^Nested_Inner, a: mem.Allocator) -> bool {
	if kd, _ := json.kind(doc, obj); kd != .Object {
		return false
	}
	seen: u8
	next := 0
	c_it := json.children(doc, obj)
	for c in json.children(&c_it) {
		switch tape_field(doc, c, t, &next) {
		case 0:
			if kd, _ := json.kind(doc, c); kd != .Array {
				return false
			}
			o.a = make([]f64, json.child_count(doc, c), a)
			k := 0
			e_it := json.children(doc, c)
			for e in json.children(&e_it) {
				o.a[k] = tape_float(doc, e) or_return
				k += 1
			}
		case 1:
			if kd, _ := json.kind(doc, c); kd != .Object {
				return false
			}
			b_seen: u8
			b_next := 0
			m_it := json.children(doc, c)
			for m in json.children(&m_it) {
				if tape_field(doc, m, bt, &b_next) == 0 {
					o.b.c = tape_int(doc, m) or_return
					b_seen = 1
				}
			}
			if b_seen != 1 {
				return false
			}
		case: continue
		}
		seen |= 1 << uint(next - 1)
	}
	return seen == 0b11
}

tape_config :: proc(data: []byte, out: ^Config_Head, a: mem.Allocator) -> bool {
	paths := [2]json.Path{{steps = []json.Step{json.Name("name")}}, {steps = []json.Step{json.Name("port")}}}
	req := json.Request({.Path}){paths = paths[:], strictness = .Strict, allocator = a}
	if json.scan(data, &req) != nil {
		return false
	}
	name, name_err := json.answers(&req, 0)
	port, port_err := json.answers(&req, 1)
	if name_err != nil || port_err != nil || len(name) != 1 || len(port) != 1 {
		return false
	}
	out.name = span_string(data, name[0], a) or_return
	out.port = span_int(data, port[0]) or_return
	return true
}

// A found string answer, borrowed unless it is escaped.
span_string :: proc(src: []byte, ans: json.Path_Answer, a: mem.Allocator) -> (string, bool) {
	if ans.outcome != .Found || ans.kind != .String {
		return "", false
	}
	d, _, ok := json.decode_span(src, ans.lo, ans.hi, .String, a)
	return d.(string) or_else "", ok
}

// A found integer answer in the `i64` range, read as unmarshal reads one.
span_int :: proc(src: []byte, ans: json.Path_Answer) -> (i64, bool) {
	if ans.outcome != .Found || ans.kind != .Number {
		return 0, false
	}
	d, _, ok := json.decode_span(src, ans.lo, ans.hi, .Number)
	v, is := d.(i64)
	return v, ok && is
}

// An integer row the way unmarshal reads one: integer spelling (no fraction, no exponent) and in range, its
// digits read from the span (a row holds no number's value).
tape_int :: proc(doc: ^json.Document, c: json.Node) -> (i64, bool) {
	r := doc.rows[c]
	if r.kind != .Number {
		return 0, false
	}
	for d in doc.src[r.lo:r.hi] {
		if d == '.' || d | 0x20 == 'e' {
			return 0, false
		}
	}
	neg := doc.src[r.lo] == '-'
	mag: u64
	for d in doc.src[r.lo + u32(neg):r.hi] {
		m, o1 := intrinsics.overflow_mul(mag, 10)
		v, o2 := intrinsics.overflow_add(m, u64(d - '0'))
		if o1 || o2 {
			return 0, false
		}
		mag = v
	}
	// The magnitude of the most negative i64; the most positive is one less.
	limit := u64(1) << 63
	if mag > limit || (!neg && mag == limit) {
		return 0, false
	}
	return i64(0 - mag if neg else mag), true
}

tape_float :: proc(doc: ^json.Document, c: json.Node) -> (f64, bool) {
	return json.get_float(doc, c)
}

// An array of integer rows.
tape_ints :: proc(doc: ^json.Document, arr: json.Node, a: mem.Allocator) -> (out: []i64, ok: bool) {
	if kd, _ := json.kind(doc, arr); kd != .Array {
		return
	}
	out = make([]i64, json.child_count(doc, arr), a)
	k := 0
	e_it := json.children(doc, arr)
	for e in json.children(&e_it) {
		out[k] = tape_int(doc, e) or_return
		k += 1
	}
	return out, true
}
