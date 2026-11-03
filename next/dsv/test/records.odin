package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import records "../../core/records"
import dsv ".."

// The row reader against a model: a plain framer that honours quotes, then `validate` of the whole text, whose fault
// ends the rows before the first whose line end is not before it.

@(private = "file")
Model_Row :: struct {
	at, hi: u64,
}

@(private = "file")
validate_as :: proc(src: string, spec: dsv.Spec, opts: dsv.Options) -> Maybe(core.Fault) {
	switch spec {
	case .Csv:   return dsv.validate(transmute([]u8)src, .Csv, opts)
	case .Tsv:   return dsv.validate(transmute([]u8)src, .Tsv, opts)
	case .Plain: return dsv.validate(transmute([]u8)src, .Plain, opts)
	}
	return nil
}

// Frames `src` byte by byte. Returns the rows, the end of the header's line, and the whole text's fault.
@(private = "file")
model_rows :: proc(src: string, spec: dsv.Spec, opts: dsv.Options) -> (out: [dynamic]Model_Row, header_end: int, fault: Maybe(core.Fault)) {
	out = make([dynamic]Model_Row, context.temp_allocator)
	fault = validate_as(src, spec, opts)
	delim: u8 = '\t' if spec == .Tsv else ','
	header := !opts.no_header
	i := 3 if strings.has_prefix(src, "\xef\xbb\xbf") else 0
	for i < len(src) {
		if src[i] == '\n' || strings.has_prefix(src[i:], "\r\n") || opts.comment != 0 && src[i] == opts.comment {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			i += 1
			continue
		}
		j := i
		first, quoted := true, false
		for j < len(src) {
			c := src[j]
			if quoted {
				if c == '"' && j + 1 < len(src) && src[j + 1] == '"' {
					j += 2
					continue
				}
				quoted = c != '"'
			} else if c == '\n' {
				break
			} else if spec == .Csv && c == '"' && first {
				quoted = true
			}
			first = c == delim
			j += 1
		}
		hi := j
		if hi > i && src[hi - 1] == '\r' {
			hi -= 1
		}
		if f, bad := fault.?; bad && u64(hi) >= f.at {
			return
		}
		if header {
			header, header_end = false, j + 1
		} else {
			append(&out, Model_Row{u64(i), u64(hi)})
		}
		i = j + 1
	}
	return
}

// Checks `records.next` and `records.check` on `src` against the model.
@(private = "file")
expect_rows :: proc(t: ^testing.T, src: string, spec: dsv.Spec, opts: dsv.Options) -> bool {
	want, _, fault := model_rows(src, spec, opts)
	it := records.open(transmute([]u8)src, dsv.as(spec, opts))
	defer records.close(&it)
	n := 0
	for rec in records.next(&it) {
		if n >= len(want) || rec.at != want[n].at || u64(len(rec.text)) != want[n].hi - want[n].at {
			testing.expectf(t, false, "%v %v %q: row %d at %d %q, want %v", spec, opts, src, n, rec.at, rec.text, want[n] if n < len(want) else Model_Row{})
			return false
		}
		n += 1
	}
	if !testing.expectf(t, n == len(want) && it.fault == fault, "%v %v %q: %d rows, fault %v, want %d, %v", spec, opts, src, n, it.fault, len(want), fault) {
		return false
	}
	faults, err := records.check(transmute([]u8)src, dsv.as(spec, opts), .Lines, context.temp_allocator)
	testing.expect_value(t, err, nil)
	f, bad := fault.?
	return testing.expectf(t, len(faults) == int(bad) && (!bad || faults[0] == f), "%v %q: check gave %v, want %v", spec, src, faults, fault)
}

@(private = "file", rodata)
CELLS := []string{"a", "12", "", "\"q,x\"", "\"l\nm\"", "\"d\"\"q\"", "é", "b\\tc", "\"\"", " s ", "-3.5", "true"}

@(private = "file")
seeded_rows :: proc(gen: rand.Generator, spec: dsv.Spec, rows: int, header := "") -> string {
	b := strings.builder_make(context.temp_allocator)
	if rand.int_max(4, gen) == 0 {
		strings.write_string(&b, "\xef\xbb\xbf")
	}
	delim: u8 = '\t' if spec == .Tsv else ','
	width := 3
	if header != "" {
		strings.write_string(&b, header)
		strings.write_byte(&b, '\n')
	}
	for r in 0 ..< rows {
		switch rand.int_max(16, gen) {
		case 0: strings.write_string(&b, "\n")
		case 1: strings.write_string(&b, "#c\n")
		}
		// A ragged row now and then.
		n := width + (rand.int_max(3, gen) - 1 if rand.int_max(12, gen) == 0 else 0)
		for c in 0 ..< max(n, 1) {
			if c > 0 {
				strings.write_byte(&b, delim)
			}
			cell := rand.choice(CELLS, gen)
			if spec != .Csv && strings.contains_any(cell, "\"\n") {
				cell = "w"
			}
			strings.write_string(&b, cell)
		}
		if r < rows - 1 || rand.int_max(2, gen) == 0 {
			strings.write_string(&b, "\r\n" if rand.int_max(4, gen) == 0 else "\n")
		}
	}
	return strings.to_string(b)
}

@(private = "file")
LAYOUTS := []dsv.Options{{}, {no_header = true}, {comment = '#'}, {no_header = true, comment = '#'}}

@(test)
rows_follow_the_model :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(5)
	gen := rand.default_random_generator(&state)
	// Each byte of a text in turn becomes a byte that breaks or ends a row.
	breakers := "\",\t\n\r\\x#\xff\xc3"
	for round in 0 ..< 120 {
		spec := dsv.Spec(round % 3)
		src := seeded_rows(gen, spec, 1 + rand.int_max(6, gen))
		buf := make([]u8, len(src), context.temp_allocator)
		for i in -1 ..< len(src) {
			for c in transmute([]u8)breakers {
				copy(buf, src)
				if i >= 0 {
					buf[i] = c
				}
				for opts in LAYOUTS {
					if !expect_rows(t, string(buf), spec, opts) {
						return
					}
				}
				if i < 0 {
					break
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

// Texts of more rows than a batch holds, and of rows too wide for its buffer, restart the walk between rows.
@(test)
rows_across_batches :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(6)
	gen := rand.default_random_generator(&state)
	breakers := "\",\n\r\xff"
	for round in 0 ..< 12 {
		spec := dsv.Spec(round % 3)
		src := seeded_rows(gen, spec, 700)
		buf := make([]u8, len(src), context.temp_allocator)
		for k in -1 ..< 40 {
			copy(buf, src)
			if k >= 0 {
				buf[rand.int_max(len(buf), gen)] = breakers[rand.int_max(len(breakers), gen)]
			}
			for opts in LAYOUTS {
				if !expect_rows(t, string(buf), spec, opts) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
	wide := strings.builder_make(context.temp_allocator)
	for r in 0 ..< 3 {
		for c in 0 ..< 50_000 {
			strings.write_string(&wide, "," if c > 0 else "")
			strings.write_string(&wide, "\"x\"" if c % 7 == 0 else "1")
		}
		strings.write_byte(&wide, '\n')
		if r == 0 {
			// Rows of 100 cells, which end batches early by the buffer, not the row count.
			for _ in 0 ..< 400 {
				strings.write_string(&wide, strings.repeat("a,", 49_999, context.temp_allocator)[:99 * 2 - 1])
				strings.write_byte(&wide, '\n')
			}
		}
	}
	expect_rows(t, strings.to_string(wide), .Csv, {no_header = true})
}

@(test)
rows_columns_cells_and_documents :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "\xef\xbb\xbfid,\"pri\"\"ce\",note\r\n1,\"2,5\",\"a\"\"b\"\n\n2,7,\"x\ny\"\n"
	it := records.open(transmute([]u8)src, dsv.as(.Csv))
	defer records.close(&it)
	price := records.column(&it, "pri\"ce")
	testing.expect_value(t, price, 1)
	testing.expect_value(t, records.column(&it, "nope"), -1)
	buf: [8]u8
	rec, ok := records.next(&it)
	testing.expect(t, ok && string(rec.text) == "1,\"2,5\",\"a\"\"b\"")
	s, got := records.cell(&it, rec, price, buf[:])
	testing.expect(t, got && s == "2,5")
	s, got = records.cell(&it, rec, 2, buf[:])
	testing.expect(t, got && s == "a\"b")
	_, got = records.cell(&it, rec, 3, buf[:])
	testing.expect(t, !got)
	_, got = records.cell(&it, rec, 2, buf[:1])
	testing.expect(t, !got)

	doc, err := records.build(&it, rec, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	path, _ := core.parse_path(".note", context.temp_allocator)
	answers, _ := core.query(&doc, path, allocator = context.temp_allocator)
	testing.expect(t, len(answers) == 1)
	text, _ := core.text(&doc, answers[0].node, buf[:])
	testing.expect_value(t, text, "a\"b")

	first := rec
	rec, ok = records.next(&it)
	testing.expect(t, ok && string(rec.text) == "2,7,\"x\ny\"")
	_, got = records.cell(&it, first, 0, buf[:])
	testing.expect(t, !got)
	_, err = records.build(&it, first, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.Bad_Index)
	_, ok = records.next(&it)
	testing.expect(t, !ok && it.fault == nil)

	// With no header a row builds as a list, and no column has a name.
	it2 := records.open(transmute([]u8)string("a,b\n"), dsv.as(.Csv, {no_header = true}))
	defer records.close(&it2)
	testing.expect_value(t, records.column(&it2, "a"), -1)
	rec, _ = records.next(&it2)
	doc, _ = records.build(&it2, rec, context.temp_allocator)
	testing.expect(t, doc.nodes[0].kind == .Array && core.length(&doc, core.ROOT) == 2)

	// Other framings are no dsv framing.
	it3 := records.open(transmute([]u8)string("a\n1\n"), dsv.as(.Csv), .Seq)
	_, ok = records.next(&it3)
	testing.expect(t, !ok && it3.fault.?.kind == .Bad_Option)
}

@(private = "file")
Record_Row :: struct {
	a: int,
	b: string,
	c: Maybe(f64),
}

@(private = "file")
Required_Record_Row :: struct {
	a: int `csv:"a,required"`,
	b: string,
}

// A typed error with the offsets past `from` moved by `by`, and its steps as text.
@(private = "file")
moved_error :: proc(e: core.Typed_Error, from, by: u64) -> string {
	e := e
	if e.kind != .None && e.at >= from {
		e.at += by
	}
	if e.kind == .Walk && e.inner.at >= from {
		e.inner.at += by
	}
	return fmt.tprint(e.kind, e.truncated, e.at, e.inner, e.steps[:e.n_steps])
}

@(private = "file")
unmarshal_as :: proc(src: string, spec: dsv.Spec, target: ^$T, plan: ^typed.Plan, read: typed.Read_Options, opts: dsv.Options) -> core.Typed_Error {
	switch spec {
	case .Csv:   return dsv.unmarshal(transmute([]u8)src, .Csv, target, plan, read, opts, context.temp_allocator)
	case .Tsv:   return dsv.unmarshal(transmute([]u8)src, .Tsv, target, plan, read, opts, context.temp_allocator)
	case .Plain: return dsv.unmarshal(transmute([]u8)src, .Plain, target, plan, read, opts, context.temp_allocator)
	}
	return {}
}

// `records.read` against `dsv.unmarshal` of the text of the header and each row the model frames, or of the row alone
// for a list row.
@(private = "file")
expect_read :: proc(t: ^testing.T, src: string, spec: dsv.Spec, opts: dsv.Options, read: typed.Read_Options, $T: typeid) -> bool {
	plan, perr := dsv.plan_make(T, spec, allocator = context.temp_allocator)
	if !testing.expect_value(t, perr.kind, core.Typed_Error_Kind.None) {
		return false
	}
	want, header_end, fault := model_rows(src, spec, opts)
	listed := T == []string
	it := records.open(transmute([]u8)src, dsv.as(spec, opts))
	defer records.close(&it)
	got_sink, want_sink: typed.Collected
	got_read, want_read := read, read
	if read.collect != nil {
		got_read.collect = &got_sink
		want_read.collect = &want_sink
	}
	n := 0
	for {
		v: T
		more, err := records.read(&it, &v, &plan, got_read, context.temp_allocator)
		if !more {
			if T == map[string]string && opts.no_header {
				return testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unsupported)
			}
			if !testing.expectf(t, err.kind == .None, "%v %q: read ended with %v", spec, src, err) {
				return false
			}
			break
		}
		if n >= len(want) {
			return testing.expectf(t, false, "%v %q: row %d past the model's", spec, src, n)
		}
		r := want[n]
		head := "" if listed || opts.no_header else src[:header_end]
		one := strings.concatenate({head, src[r.at:r.hi]}, context.temp_allocator)
		w: T
		mark := len(want_sink.errors)
		row_opts := opts
		row_opts.no_header ||= listed
		e := unmarshal_as(one, spec, &w, &plan, want_read, row_opts)
		from, by := u64(len(head)), r.at - u64(len(head))
		want_err := moved_error(e, from, by)
		for &x in want_sink.errors[mark:] {
			x.at += by if x.at >= from else 0
		}
		got_err := moved_error(err, 0, 0)
		if !testing.expectf(t, got_err == want_err, "%v %v %v %q: row %d at %d: %s, want %s", spec, opts, read, src, n, r.at, got_err, want_err) {
			return false
		}
		same := fmt.tprint(v) == fmt.tprint(w)
		when T == map[string]string {
			same = len(v) == len(w)
			for k, x in v {
				same &&= w[k] == x
			}
		}
		if !testing.expectf(t, same, "%v %q: row %d read %v, want %v", spec, src, n, v, w) {
			return false
		}
		n += 1
	}
	if !testing.expectf(t, n == len(want) && it.fault == fault, "%v %q: %d rows, fault %v, want %d, %v", spec, src, n, it.fault, len(want), fault) {
		return false
	}
	return testing.expectf(t, fmt.tprint(got_sink.errors[:]) == fmt.tprint(want_sink.errors[:]), "%v %q: collected %v, want %v", spec, src, got_sink.errors[:], want_sink.errors[:])
}

@(test)
rows_read_as_unmarshal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(7)
	gen := rand.default_random_generator(&state)
	headers := []string{"a,b,c", "b,a,x", "a,a,c", "c,b,\"a\"", "x,y,z"}
	breakers := "\",\n1x"
	sink: typed.Collected
	reads := []typed.Read_Options{{borrow_strings = true}, {collect = &sink}, {refuse_duplicates = true}, {unknown = .Refuse}}
	for round in 0 ..< 30 {
		spec := dsv.Spec(round % 3)
		header := rand.choice(headers, gen)
		if spec == .Tsv {
			header, _ = strings.replace_all(header, ",", "\t", context.temp_allocator)
		}
		src := seeded_rows(gen, spec, 1 + rand.int_max(4, gen), header)
		buf := make([]u8, len(src), context.temp_allocator)
		for i in -1 ..< len(src) {
			for c in transmute([]u8)breakers {
				copy(buf, src)
				if i >= 0 {
					buf[i] = c
				}
				for opts in LAYOUTS[:2] {
					for read in reads {
						ok := expect_read(t, string(buf), spec, opts, read, Record_Row) && expect_read(t, string(buf), spec, opts, read, Required_Record_Row) && expect_read(t, string(buf), spec, opts, read, []string) && expect_read(t, string(buf), spec, opts, read, map[string]string)
						if !ok {
							return
						}
					}
				}
				if i < 0 {
					break
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
row_target_reads_one_record :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	row: Record_Row
	e := dsv.unmarshal(transmute([]u8)string("a,b\n1,x\n"), .Csv, &row, {borrow_strings = true}, {}, context.temp_allocator)
	testing.expect(t, e.kind == .None && row.a == 1 && row.b == "x")
	e = dsv.unmarshal(transmute([]u8)string("a,b\n1,x\n2,y\n"), .Csv, &row, {}, {}, context.temp_allocator)
	testing.expectf(t, e.kind == .Wrong_Length && e.at == 8 && row.a == 1, "%v %v", e, row)
	// A row written by `marshal` reads back.
	text, merr := dsv.marshal(Record_Row{a = 3, b = "q,r", c = 1.5}, .Csv, allocator = context.temp_allocator)
	testing.expect_value(t, merr.kind, core.Typed_Error_Kind.None)
	back: Record_Row
	e = dsv.unmarshal(text, .Csv, &back, {}, {}, context.temp_allocator)
	testing.expect(t, e.kind == .None && back.a == 3 && back.b == "q,r" && back.c.? == 1.5)
}
