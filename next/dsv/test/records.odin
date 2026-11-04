package dsv_tests

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import core "../../core"
import host "../../host"
import typed "../../core/typed"
import records "../../core/records"
import dsv ".."
import walktest "../../walktest"

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
LAYOUTS := []dsv.Options{{}, {no_header = true}, {comment = '#'}, {no_header = true, comment = '#'}, {tolerate = {.Invalid_Utf8, .Ragged, .Bare_Quote}}}

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

// A text read in pieces on threads against the same text read on one, and `records.validate` against `validate`: the
// same faults at the same bytes, at every width. The tests build pieces of one byte, so every byte is a cut, inside
// quoted cells and CRLF pairs among them.
@(private = "file")
expect_chain_law :: proc(t: ^testing.T, pools: []host.Pool, src: string, spec: dsv.Spec, opts: dsv.Options) -> bool {
	text, as := transmute([]u8)src, dsv.as(spec, opts)
	serial, _ := records.check(text, as, .Lines, context.temp_allocator)
	whole := dsv.validate(text, spec, opts)
	if v := records.validate(text, as); !testing.expectf(t, v == whole, "%v %v %q: validate %v, want %v", spec, opts, src, v, whole) {
		return false
	}
	for &pool in pools {
		got, _ := records.check(text, as, .Lines, context.temp_allocator, &pool.runner)
		if !testing.expectf(t, slice.equal(got, serial), "%v %v %q at width %d: %v, want %v", spec, opts, src, pool.runner.threads + 1, got, serial) {
			return false
		}
		if v := records.validate(text, as, &pool.runner); !testing.expectf(t, v == whole, "%v %v %q at width %d: validate %v, want %v", spec, opts, src, pool.runner.threads + 1, v, whole) {
			return false
		}
	}
	return walktest.expect_each_law(t, pools, text, as, .Lines)
}

@(test)
records_check_on_threads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pools: [4]host.Pool
	for w, i in ([4]int{1, 2, 6, 18}) {
		host.pool_init(&pools[i], w)
	}
	defer for &p in pools {
		host.pool_destroy(&p)
	}
	state := rand.create(7)
	gen := rand.default_random_generator(&state)
	breakers := "\",\n\r\xff"
	for round in 0 ..< 24 {
		spec := dsv.Spec(round % 3)
		src := seeded_rows(gen, spec, 12)
		buf := make([]u8, len(src), context.temp_allocator)
		for i in -1 ..< len(src) {
			copy(buf, src)
			if i >= 0 {
				buf[i] = breakers[rand.int_max(len(breakers), gen)]
			}
			for opts in LAYOUTS {
				if !expect_chain_law(t, pools[:], string(buf), spec, opts) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
	// Past a bare quote, quoted cells hold text that a piece cut inside them reads as rows.
	cells := strings.repeat("2,\"a\n7,8\n9,10\nb\"\n", 4, context.temp_allocator)
	expect_chain_law(t, pools[:], strings.concatenate({"h,k\n0,ok\n1,x\"y\n", cells}, context.temp_allocator), .Csv, {})
}

// Under `.Ragged` a wide row's cells past the header's last are columns named by position, in memory, on a stream and in
// a check on threads. A header cell of that name is the column `column` finds, and a built row takes the last of the two.
@(test)
rows_name_wide_cells_by_position :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "3,b\n1,2\n4,5,6,7\n"
	as := dsv.as(.Csv, {tolerate = {.Ragged}})
	pool: host.Pool
	host.pool_init(&pool, 2)
	defer host.pool_destroy(&pool)
	faults, _ := records.check(transmute([]u8)src, as, .Lines, context.temp_allocator, &pool.runner)
	testing.expect_value(t, len(faults), 0)
	testing.expect_value(t, records.validate(transmute([]u8)src, as, &pool.runner), nil)
	path, _ := core.parse_path(`.["4"]`, context.temp_allocator)
	same, _ := core.parse_path(`.["3"]`, context.temp_allocator)
	for stream in ([]bool{false, true}) {
		c := Chunked{src = transmute([]u8)src, sizes = {1}}
		it := records.open_stream(chunked(&c), as) if stream else records.open(transmute([]u8)src, as)
		testing.expect_value(t, records.column(&it, "3"), 0)
		testing.expect_value(t, records.column(&it, "4"), 3)
		testing.expect_value(t, records.column(&it, "2"), -1)
		buf: [8]u8
		_, _ = records.next(&it)
		rec, ok := records.next(&it)
		testing.expect(t, ok && string(rec.text) == "4,5,6,7")
		s, got := records.cell(&it, rec, 3, buf[:])
		testing.expect(t, got && s == "7")
		doc, err := records.build(&it, rec, context.temp_allocator)
		testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
		want := []string{"7", "6"}
		for p, i in ([]core.Path{path, same}) {
			answers, _ := core.query(&doc, p, allocator = context.temp_allocator)
			text: string
			if len(answers) == 1 {
				text, _ = core.text(&doc, answers[0].node, buf[:])
			}
			testing.expectf(t, text == want[i], "stream %v, path %d: %q", stream, i, text)
		}
		records.close(&it)
	}
}

@(test)
rows_scan_by_their_header :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a,b\n1,2\n3,5\n\"x,\"\"y\",4\n"
	path, _ := core.parse_path(".a", context.temp_allocator)
	it := records.open(transmute([]u8)src, dsv.as(.Csv))
	defer records.close(&it)
	got := make([dynamic]string, context.temp_allocator)
	buf: [8]u8
	for {
		_, doc, err, more := records.scan(&it, path)
		if !more {
			break
		}
		text, _ := core.text(&doc, doc.answers[0].node, buf[:])
		append(&got, fmt.tprint(err.kind, text))
	}
	testing.expect_value(t, fmt.tprint(got[:]), `["None 1", "None 3", "None x,\"y"]`)
}

@(test)
rows_give_all_their_cells :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := "a,b,c,d\n,\"\",x,\"p\"\"q\"\n1,2,3,4\n"
	for stream in ([]bool{false, true}) {
		c := Chunked{src = transmute([]u8)src, sizes = {1}}
		as := dsv.as(.Csv)
		it := records.open_stream(chunked(&c), as) if stream else records.open(transmute([]u8)src, as)
		buf: [8]u8
		rec, _ := records.next(&it)
		cells, ok := records.cells(&it, rec, buf[:])
		testing.expectf(t, ok && fmt.tprint(cells) == `[nil, "", "x", "p\"q"]`, "stream %v: %v", stream, cells)
		_, ok = records.cells(&it, rec, buf[:2])
		testing.expect(t, !ok)
		first := rec
		rec, _ = records.next(&it)
		_, ok = records.cells(&it, first, buf[:])
		testing.expect(t, !ok)
		cells, ok = records.cells(&it, rec, nil)
		testing.expectf(t, ok && fmt.tprint(cells) == `["1", "2", "3", "4"]`, "stream %v: %v", stream, cells)
		records.close(&it)
	}
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

	// A framing dsv does not take is refused on a stream too.
	r: bytes.Reader
	it4 := records.open_stream(bytes.reader_init(&r, transmute([]u8)string("a\n1\n")), dsv.as(.Csv), .Seq)
	defer records.close(&it4)
	_, ok = records.next(&it4)
	testing.expect(t, !ok && it4.fault.?.kind == .Bad_Option)
}

@(private = "file")
Record_Row :: struct {
	a: int,
	b: string,
	c: Maybe(f64),
	d: Maybe(string) `csv:"4"`,
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
	headers := []string{"a,b,c", "b,a,x", "a,a,c", "c,b,\"a\"", "x,y,z", "4,a,b"}
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
				for opts in ([]dsv.Options{LAYOUTS[0], LAYOUTS[1], LAYOUTS[4]}) {
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

// A reader that gives `sizes[n]` bytes at a time, cycling, or random sizes when `sizes` is empty.
@(private = "file")
Chunked :: struct {
	src:   []u8,
	sizes: []int,
	gen:   rand.Generator,
	reads: int,
	at:    int,
}

@(private = "file")
chunked :: proc(c: ^Chunked) -> io.Reader {
	return {data = c, procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		c := (^Chunked)(data)
		if mode != .Read {
			return 0, .Unsupported
		}
		if c.at == len(c.src) {
			return 0, .EOF
		}
		k := c.sizes[c.reads % len(c.sizes)] if len(c.sizes) > 0 else 1 + rand.int_max(16, c.gen)
		c.reads += 1
		n := copy(p[:min(len(p), k)], c.src[c.at:])
		c.at += n
		return i64(n), nil
	}}
}

@(private = "file")
Got :: struct {
	rows:  [dynamic]string,
	fault: Maybe(core.Fault),
	held:  string,
	at:    u64,
}

// Every row of `it` as its offset, text, cells, named column and built document's `b` answer, copied since a stream's
// bytes are gone at the next call.
@(private = "file")
drain :: proc(it: ^records.Reader) -> (g: Got) {
	g.rows = make([dynamic]string, context.temp_allocator)
	path, _ := core.parse_path(".b", context.temp_allocator)
	buf: [64]u8
	col := records.column(it, "b")
	for rec in records.next(it) {
		cells := make([dynamic]string, context.temp_allocator)
		for c in 0 ..< 5 {
			s, ok := records.cell(it, rec, c, buf[:])
			append(&cells, fmt.tprint(ok, s))
		}
		named: string
		doc, err := records.build(it, rec, context.temp_allocator)
		if answers, _ := core.query(&doc, path, allocator = context.temp_allocator); len(answers) == 1 {
			named, _ = core.text(&doc, answers[0].node, buf[:])
		}
		append(&g.rows, fmt.tprint(rec.at, string(rec.text), col, cells[:], err.kind, named))
	}
	g.fault, g.held, g.at = it.fault, strings.clone(string(it.held), context.temp_allocator), it.held_at
	return
}

// A stream of `src` read in chunks gives the rows and fault `src` in memory gives, but for a last row the input ends
// inside, which it holds.
@(private = "file")
expect_stream :: proc(t: ^testing.T, src: string, spec: dsv.Spec, opts: dsv.Options, sizes: []int, gen: rand.Generator) -> bool {
	mem := records.open(transmute([]u8)src, dsv.as(spec, opts))
	defer records.close(&mem)
	want := drain(&mem)
	c := Chunked{src = transmute([]u8)src, sizes = sizes, gen = gen}
	st := records.open_stream(chunked(&c), dsv.as(spec, opts))
	defer records.close(&st)
	got := drain(&st)
	n := len(got.rows)
	same := n <= len(want.rows)
	for i in 0 ..< min(n, len(want.rows)) {
		same &&= got.rows[i] == want.rows[i]
	}
	if len(got.held) == 0 {
		same &&= n == len(want.rows) && got.fault == want.fault
	} else {
		same &&= got.fault == nil && got.at + u64(len(got.held)) == u64(len(src)) && src[got.at:] == got.held
		f, bad := want.fault.?
		same &&= bad && f.kind == .Truncated && f.at == u64(len(src)) && n == len(want.rows)
	}
	return testing.expectf(t, same && st.cause == nil, "%v %v %v %q: stream %v %v held %q at %d, memory %v %v", spec, opts, sizes, src, got.rows[:], got.fault, got.held, got.at, want.rows[:], want.fault)
}

@(test)
rows_stream_as_in_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(8)
	gen := rand.default_random_generator(&state)
	sizes := [][]int{{1}, {2}, {3}, {7}, {64}, {}}
	breakers := "\",\n\r\xff\xc3x"
	for round in 0 ..< 150 {
		spec := dsv.Spec(round % 3)
		// The longer texts cross a batch and several windows.
		rows := 700 if round % 5 == 0 else 1 + rand.int_max(8, gen)
		src := seeded_rows(gen, spec, rows, "a\tb\tc" if spec == .Tsv else "a,b,c")
		buf := transmute([]u8)strings.clone(src, context.temp_allocator)
		if round % 2 == 1 {
			buf[rand.int_max(len(buf), gen)] = breakers[rand.int_max(len(breakers), gen)]
		}
		for opts in LAYOUTS {
			for s in sizes {
				if !expect_stream(t, string(buf), spec, opts, s, gen) {
					return
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

// Every chunk size up to a text's length moves the window at a different byte, the header's line and quoted line ends
// included.
@(test)
rows_stream_at_every_chunk_size :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(11)
	gen := rand.default_random_generator(&state)
	texts := []string{"a,b,c\r\n1,\"x\ny\",3\r\n4,5,6\r\n\"7\"\"\",8,9", "a,b\n1,2\n3\n4,5\n", "a\tb\n1\t2\n3\t4\n"}
	for src, i in texts {
		spec := dsv.Spec.Tsv if i == 2 else .Csv
		for size in 1 ..= len(src) {
			for opts in LAYOUTS {
				if !expect_stream(t, src, spec, opts, {size}, gen) {
					return
				}
			}
		}
	}
}

// An input that ends at any byte of its last row holds that row or gives the fault memory gives, never a wrong row.
@(test)
rows_stream_holds_a_cut_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(9)
	gen := rand.default_random_generator(&state)
	head := "a,b,c\n1,2,3\n"
	src := strings.concatenate({head, "\"q,\nx\",é,\"é\"\"\"\n"}, context.temp_allocator)
	for k in len(head) + 1 ..< len(src) {
		for s in ([][]int{{1}, {3}, {}}) {
			if !expect_stream(t, src[:k], .Csv, {}, s, gen) {
				return
			}
		}
	}
	// A cut inside an encoded character is held.
	c := Chunked{src = transmute([]u8)string("a,b\n1,\xc3"), sizes = {2}}
	it := records.open_stream(chunked(&c), dsv.as(.Csv))
	defer records.close(&it)
	n := 0
	for _ in records.next(&it) {
		n += 1
	}
	testing.expectf(t, n == 0 && it.fault == nil && string(it.held) == "a,b\n1,\xc3", "%d rows, %v, held %q", n, it.fault, it.held)
}

// `records.read` on a stream gives what it gives in memory, with the same offsets in its errors.
@(test)
rows_stream_read_as_in_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	state := rand.create(10)
	gen := rand.default_random_generator(&state)
	headers := []string{"a,b,c", "b,x,a", "a,a,c", "x,y,z", "4,a,b"}
	for round in 0 ..< 60 {
		spec := dsv.Spec(round % 2)
		opts := LAYOUTS[4] if round % 3 == 0 else {}
		header, _ := strings.replace_all(headers[round % 5], ",", "\t" if spec == .Tsv else ",", context.temp_allocator)
		src := seeded_rows(gen, spec, 1 + rand.int_max(40, gen), header)
		plan, _ := dsv.plan_make(Required_Record_Row, spec, allocator = context.temp_allocator)
		mplan, _ := dsv.plan_make(map[string]string, spec, allocator = context.temp_allocator)
		mem := records.open(transmute([]u8)src, dsv.as(spec, opts))
		c := Chunked{src = transmute([]u8)src, sizes = {1 + round % 7}}
		st := records.open_stream(chunked(&c), dsv.as(spec, opts))
		ms, ss: typed.Collected
		ms.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
		ss.errors = make([dynamic]core.Typed_Error, context.temp_allocator)
		for {
			v, w: Required_Record_Row
			more, err := records.read(&st, &v, &plan, {collect = &ss, unknown = .Refuse}, context.temp_allocator)
			wmore, werr := records.read(&mem, &w, &plan, {collect = &ms, unknown = .Refuse}, context.temp_allocator)
			if !more {
				break
			}
			if !testing.expectf(t, wmore && moved_error(err, 0, 0) == moved_error(werr, 0, 0) && fmt.tprint(v) == fmt.tprint(w), "%q: read %v %v, memory %v %v", src, v, err, w, werr) {
				return
			}
			m, wm: map[string]string
			_, merr := records.read(&st, &m, &mplan, {}, context.temp_allocator)
			_, wmerr := records.read(&mem, &wm, &mplan, {}, context.temp_allocator)
			if !testing.expectf(t, moved_error(merr, 0, 0) == moved_error(wmerr, 0, 0) && len(m) == len(wm), "%q: map %v %v, memory %v %v", src, m, merr, wm, wmerr) {
				return
			}
		}
		testing.expectf(t, fmt.tprint(ss.errors[:]) == fmt.tprint(ms.errors[:]), "%q: collected %v, memory %v", src, ss.errors[:], ms.errors[:])
		records.close(&mem)
		records.close(&st)
		free_all(context.temp_allocator)
	}
}

// A reader's memory does not grow with the rows it reads: map and struct rows, refused rows, and wide rows.
@(test)
rows_read_in_bounded_memory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Number_Row :: struct {
		a: int,
		b: string,
	}
	text :: proc(spec: dsv.Spec, body: string, n: int) -> []u8 {
		s := strings.concatenate({"a,b,\"c\"\"d\"\n", strings.repeat(body, n, context.temp_allocator)}, context.temp_allocator)
		if spec == .Tsv {
			s, _ = strings.replace_all(s, ",", "\t", context.temp_allocator)
		}
		return transmute([]u8)s
	}
	for spec in ([]dsv.Spec{.Csv, .Tsv}) {
		for opts in ([]dsv.Options{{}, {tolerate = {.Ragged}}}) {
			body := "1,x,\"q\"\"r\"\ny,2,3\n4,5,6,7,8\n" if .Ragged in opts.tolerate else "1,x,\"q\"\"r\"\ny,2,3\n"
			few, many, as := text(spec, body, 100), text(spec, body, 1000), dsv.as(spec, opts)
			maps, _ := dsv.plan_make(map[string]string, spec, allocator = context.temp_allocator)
			ints, _ := dsv.plan_make(map[string]int, spec, allocator = context.temp_allocator)
			rows, _ := dsv.plan_make(Number_Row, spec, allocator = context.temp_allocator)
			_ = walktest.expect_bounded_reads(t, few, many, as, &maps, map[string]string) &&
			walktest.expect_bounded_reads(t, few, many, as, &ints, map[string]int) &&
			walktest.expect_bounded_reads(t, few, many, as, &rows, Number_Row) &&
			walktest.expect_bounded_reads(t, few, many, as, &rows, Number_Row, {unknown = .Refuse, refuse_duplicates = true})
		}
	}
}
