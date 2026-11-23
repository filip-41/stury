package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// Every read of a delimited text under an allocator that refuses its nth allocation, for each n up to the first run that
// refuses none: it returns an error or the same answer, and frees every block it made.

@(private = "file")
Read :: enum {
	Build,
	Build_On_A_Runner,
	Validate,
	Find,
	Scan,
	Build_In_Pieces,
	Validate_In_Pieces,
	Find_In_Pieces,
	Scan_In_Pieces,
	Records,
	Records_In_Pieces,
}

@(private = "file")
Run :: struct {
	read: Read,
	src:  []u8,
	spec: dsv.Spec,
	opts: tape.Options,
}

@(private = "file")
HEADER_PATH := []tape.Step{tape.Index(1), tape.Name("k1")}

@(private = "file")
COLUMN_PATH := []tape.Step{tape.All{}, tape.Index(0)}

// A text with `columns` header cells past what a read keeps in its own frame when it is wide, comment lines before and
// between its records, and a foot.
@(private = "file")
wide_text :: proc(columns: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# lead\n")
	for i in 0 ..< columns {
		fmt.sbprintf(&b, "%sk%d", "," if i > 0 else "", i % 40)
	}
	strings.write_string(&b, "\n#mid\n")
	for row in 0 ..< 4 {
		for i in 0 ..< columns {
			fmt.sbprintf(&b, "%s%d", "," if i > 0 else "", i + row)
		}
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "# foot\n")
	return strings.to_string(b)
}

@(private = "file")
read_under :: proc(data: rawptr, a: runtime.Allocator) {
	run := (^Run)(data)
	reads, f := dsv.reads(run.spec), dsv.as(run.spec)
	opts := run.opts
	switch run.read {
	case .Build:
		doc, _ := dsv.build(run.src, run.spec, opts, a)
		dsv.destroy(&doc)
	case .Build_On_A_Runner:
		runner := tape.Runner {
			threads = 3,
			start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {},
			finish = proc(data: rawptr) {},
		}
		opts.runner = &runner
		doc, _ := dsv.build(run.src, run.spec, opts, a)
		dsv.destroy(&doc)
	case .Validate:
		_ = dsv.validate(run.src, run.spec, opts, a)
	case .Find:
		_, _ = dsv.find(run.src, HEADER_PATH, run.spec, {}, opts, a)
		_, _ = dsv.find(run.src, COLUMN_PATH, run.spec, {stop_early = true}, opts, a)
	case .Scan:
		d, _ := dsv.demand_of({HEADER_PATH, COLUMN_PATH})
		defer dsv.destroy(&d)
		doc, _ := dsv.scan(run.src, &d, run.spec, {}, opts, a)
		dsv.destroy(&doc)
	case .Build_In_Pieces, .Validate_In_Pieces, .Find_In_Pieces, .Scan_In_Pieces:
		d: dsv.Demand
		defer if run.read == .Scan_In_Pieces {
			dsv.destroy(&d)
		}
		if run.read == .Scan_In_Pieces {
			d, _ = dsv.demand_of({HEADER_PATH, COLUMN_PATH})
		}
		p := tape.Pieces {
			allocator = a,
		}
		defer tape.destroy(&p)
		opts.pieces = &p
		text := slice.clone(run.src)
		defer delete(text)
		dropped: u64
		size := 70 if len(run.src) < 2000 else 211
		for end := size; ; end += size {
			last := end >= len(text)
			end = min(end, len(text))
			p.from, p.last = p.keep, last
			slice.fill(text[dropped:p.keep], 0xFF)
			dropped = p.keep
			window := text[p.keep:end]
			ok: bool
			#partial switch run.read {
			case .Build_In_Pieces:
				doc, err := dsv.build(window, run.spec, opts, a)
				dsv.destroy(&doc)
				ok = err == nil
			case .Validate_In_Pieces:
				ok = dsv.validate(window, run.spec, opts, a) == nil
			case .Find_In_Pieces:
				_, err := dsv.find(window, HEADER_PATH, run.spec, {}, opts, a)
				ok = err == nil
			case .Scan_In_Pieces:
				doc, err := dsv.scan(window, &d, run.spec, {}, opts, a)
				dsv.destroy(&doc)
				ok = err == nil
			}
			if !ok || !p.more || last {
				break
			}
		}
	case .Records, .Records_In_Pieces:
		p := tape.Pieces {
			allocator = a,
		}
		defer tape.destroy(&p)
		text := slice.clone(run.src)
		defer delete(text)
		window := text
		if run.read == .Records_In_Pieces {
			opts.pieces = &p
			window = text[:min(len(text), 90)]
		}
		records, err := reads.records(f, window, .Lines, opts, a)
		if err != nil {
			return
		}
		defer tape.destroy_records(records)
		out: [3]tape.Record
		answers: [3]tape.Span_Answer
		for _ in 0 ..< 40 {
			n := tape.records_find(records, HEADER_PATH, out[:], answers[:], {}, a)
			if records.err != nil || records.at == .Done {
				break
			}
			if run.read == .Records_In_Pieces && n < len(out) && p.more {
				p.from = p.keep
				end := min(len(text), int(p.at) + 90)
				p.last = end == len(text)
				if tape.records_window(records, text[p.from:end]) != nil {
					break
				}
				continue
			}
			if n < len(out) {
				break
			}
		}
	}
}

// Whatever allocation a read is refused, it ends with the error or its answer and leaks nothing: builds, on a runner
// and in pieces, validates, finds, scans and records, whole and in pieces, of wide headers, comment lines, repeated
// names, ragged and quoted records.
@(test)
reads_free_what_they_made_when_an_allocation_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "#h\nid,name,note,k,k\n")
	for i in 0 ..< 60 {
		fmt.sbprintf(&b, "%d,\"n,%d\",\"line\nbreak\"\"x\",v%d,\xc3\xa9\n", i, i, i)
		if i % 17 == 0 {
			strings.write_string(&b, "#c\n")
		}
	}
	texts := []string{wide_text(150), "# c\na,b,a\n1,2,3\n#f\n4,5,6\n", "a,b\n1,2,3\n4\n\"x,\ny\",z\n", "a\tb\n1\\t\tx\n", strings.to_string(b)}
	option_sets := []tape.Options {
		{},
		{format = dsv.Dsv_Options{comment = '#', infer = true}, dups = .First, tolerate = {.Ragged, .Bare_Quote, .Invalid_Utf8}},
		{format = dsv.Dsv_Options{no_header = true}},
		{dups = .All, tolerate = {.Ragged}, format = dsv.Dsv_Options{comment = '#'}},
		{dups = .Refuse, format = dsv.Dsv_Options{comment = '#'}},
	}
	runs, refused := 0, 0
	for text in texts {
		for spec in dsv.Spec {
			for opts in option_sets {
				for read in Read {
					run := Run{read, transmute([]u8)text, spec, opts}
					s := testkit.sweep_failures(read_under, &run, 800)
					runs, refused = runs + s.runs, refused + s.refused
					if !testing.expectf(t, s.bad == 0, "%v of %v %q under %v: a run refused at %d left a block or freed one twice", read, spec, text[:min(len(text), 24)], opts, s.first_bad) {
						return
					}
				}
			}
		}
	}
	testing.expectf(t, refused > 1000, "%d refusals in %d runs", refused, runs)
}
