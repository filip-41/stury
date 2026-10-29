// The walk against the current tree's csv: `validate`'s verdict on seeded texts and mutations of them, and on a valid
// text the walk's tokens against the fields of `records`. `make test-oracle` builds it from a copy of next/ with its
// packages renamed, since both trees name a package `core`.
package dsv_oracle

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:testing"
import cur "stury:csv"
import core "../../../core"
import dsv "../.."
import gen "../gen"

SEED :: #config(SEED, 1)
ROUNDS :: #config(ROUNDS, 100_000)

@(test)
agrees_with_current_tree :: proc(t: ^testing.T) {
	state := rand.create(SEED)
	context.random_generator = rand.default_random_generator(&state)
	text, broken: [dynamic]u8
	defer delete(text)
	defer delete(broken)
	log: [dynamic]core.Token
	defer delete(log)
	compared := 0
	for round in 0 ..< ROUNDS {
		tsv := round % 2 == 1
		gen.text(&text, tsv)
		gen.mutate(&broken, text[:])
		for src in ([][]u8{text[:], broken[:]}) {
			compared += 1
			if !check(t, src, tsv, &log) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("seed %d: %d compared", SEED, compared)
}

check :: proc(t: ^testing.T, src: []u8, tsv: bool, log: ^[dynamic]core.Token) -> bool {
	opts := cur.Read_Opts{dialect = cur.TSV} if tsv else {}
	want, refused := cur.validate(src, opts).?
	got, bad := (dsv.validate(src, .Tsv) if tsv else dsv.validate(src, .Csv)).?
	same := refused == bad && (!bad || fmt.tprint(want.kind) == fmt.tprint(got.kind) && want.offset == got.offset && want.detail == got.detail)
	if !testing.expectf(t, same, "%q: %v, current tree %v", src, got, want) {
		return false
	}
	return refused || tokens_agree(t, src, tsv, false, log) && tokens_agree(t, src, tsv, true, log)
}

log_hook :: proc "contextless" (h: ^[dynamic]core.Token, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	context = runtime.default_context()
	append(h, t)
	return s, .Next
}

// The walk's tokens of a valid text against the fields of the current tree's `records`: per record after the
// header a `Map` (an `Array` with no header), per field the header field of its column as a `Key` and the field as a
// `Plain` value, and an `End` on the record's line end.
tokens_agree :: proc(t: ^testing.T, src: []u8, tsv, no_header: bool, log: ^[dynamic]core.Token) -> bool {
	clear(log)
	regs: core.Hook_Regs
	hi: u64
	fault: Maybe(core.Fault)
	if tsv {
		hi, fault = dsv.walk(src, 0, .Tsv, {no_header}, log, &regs, log_hook)
	} else {
		hi, fault = dsv.walk(src, 0, .Csv, {no_header}, log, &regs, log_hook)
	}
	if !testing.expectf(t, fault == nil && hi == u64(len(src)), "%q: walk of a valid text: %d %v", src, hi, fault) {
		return false
	}
	want: [dynamic]core.Token
	defer delete(want)
	append(&want, core.Token{0, 0, .Array, .Value, 0})
	it := cur.records(src, {dialect = cur.TSV} if tsv else {})
	defer cur.destroy(&it)
	header: [dynamic]cur.Field
	defer delete(header)
	first := !no_header
	for rec in cur.next_record(&it) {
		if first {
			append(&header, ..rec.fields)
			first = false
			continue
		}
		append(&want, core.Token{rec.at, 0, .Array if no_header else .Map, .Value, 0})
		for f, col in rec.fields {
			if !no_header {
				append(&want, cell(src, header[col], .Key, tsv))
			}
			append(&want, cell(src, f, .Value, tsv))
		}
		end := rec.fields[len(rec.fields) - 1].hi
		ends := u32(0)
		if end < u64(len(src)) {
			ends = 2 if src[end] == '\r' else 1
		}
		append(&want, core.Token{end, ends, .End, .Value, 0})
	}
	append(&want, core.Token{u64(len(src)), 0, .End, .Value, 0})
	ok := testing.expectf(t, it.err == nil, "%q: the current tree's records failed on a text its validate accepts: %v", src, it.err)
	ok &&= testing.expectf(t, len(log) == len(want), "%q no_header %v: %d tokens, want %d", src, no_header, len(log), len(want))
	for i in 0 ..< min(len(log), len(want)) {
		if !ok {
			break
		}
		ok &&= testing.expectf(t, log[i] == want[i], "%q no_header %v: token %d %v, want %v", src, no_header, i, log[i], want[i])
	}
	return ok
}

cell :: proc(src: []u8, f: cur.Field, role: core.Role, tsv: bool) -> core.Token {
	quoted := !tsv && f.hi > f.lo && src[f.lo] == '"'
	return {f.lo, u32(f.hi - f.lo), .Plain, role, u16(quoted)}
}
