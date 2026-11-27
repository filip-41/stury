package cli

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "stury:engine"
import "stury:lib/core/tape"
import "stury:lib/query"

EXIT_OK :: 0
EXIT_FALSY :: 1
EXIT_USAGE :: 2
EXIT_COMPILE :: 3
EXIT_NO_OUTPUT :: 4
EXIT_RUNTIME :: 5

// Buffered streaming sink writing in fixed 64 KiB (`engine.WRITE_SINK_BYTES`) chunks with `--unbuffered`,
// `--each` line prefixing (with optional color), and write/flush error tracking.
Out_Stream :: struct {
	w:             io.Writer,
	buf:           [engine.WRITE_SINK_BYTES]u8,
	cursor:        int,
	total_written: u64,
	last_byte:     u8,
	no_io_flush:   bool,
	unbuffered:    bool,
	failed:        bool,
	reported:      bool,
	io_err:        io.Error,
	file_label:    string,
	color_label:   bool,
	open_line:     bool,
}

out_stream_init :: proc(s: ^Out_Stream, w: io.Writer, unbuffered := false, color_label := false) {
	s^ = {
		w           = w,
		no_io_flush = (w.data == rawptr(os.stdout) || w.data == rawptr(os.stderr)),
		unbuffered  = unbuffered,
		color_label = color_label,
	}
}

out_stream_flush :: proc(s: ^Out_Stream) -> bool {
	if s.failed {
		return false
	}
	left := s.buf[:s.cursor]
	s.cursor = 0
	for len(left) > 0 {
		wrote, err := io.write(s.w, left)
		if err == .None && wrote <= 0 {
			err = .Short_Write
		}
		if err != .None {
			s.failed, s.io_err = true, err
			return false
		}
		left = left[wrote:]
	}
	if !s.no_io_flush {
		if f, ok := io.to_flusher(s.w); ok {
			if ferr := io.flush(f); ferr != .None {
				s.failed, s.io_err = true, ferr
				return false
			}
		}
	}
	return true
}

out_stream_write_raw :: proc(s: ^Out_Stream, p: []u8) -> bool {
	if s.failed {
		return false
	}
	for rem := p; len(rem) > 0; {
		space := len(s.buf) - s.cursor
		if space == 0 {
			if !out_stream_flush(s) {
				return false
			}
			space = len(s.buf)
		}
		if s.cursor == 0 && len(rem) >= len(s.buf) {
			wrote, err := io.write(s.w, rem)
			if wrote > 0 {
				s.total_written += u64(wrote)
				s.last_byte = rem[wrote - 1]
			}
			if err == .None && wrote <= 0 {
				err = .Short_Write
			}
			if err != .None {
				s.failed, s.io_err = true, err
				return false
			}
			rem = rem[wrote:]
			continue
		}
		take := min(space, len(rem))
		copy(s.buf[s.cursor:], rem[:take])
		s.cursor += take
		if take > 0 {
			s.total_written += u64(take)
			s.last_byte = rem[take - 1]
		}
		rem = rem[take:]
	}
	return true
}

@(private = "file")
out_stream_write_label :: proc(s: ^Out_Stream) -> bool {
	if s.color_label {
		return out_stream_write_raw(s, transmute([]u8)string("\e[35m")) &&
			out_stream_write_raw(s, transmute([]u8)s.file_label) &&
			out_stream_write_raw(s, transmute([]u8)string("\e[0m:"))
	}
	return out_stream_write_raw(s, transmute([]u8)s.file_label) &&
		out_stream_write_raw(s, transmute([]u8)string(":"))
}

out_stream_write :: proc(s: ^Out_Stream, b: []u8) -> bool {
	if s.failed {
		return false
	}
	if s.file_label == "" {
		return out_stream_write_raw(s, b)
	}
	from := 0
	for ch, i in b {
		if !s.open_line {
			if (i > from && !out_stream_write_raw(s, b[from:i])) || !out_stream_write_label(s) {
				return false
			}
			from = i
			s.open_line = true
		}
		s.open_line = ch != '\n'
	}
	return len(b) <= from || out_stream_write_raw(s, b[from:])
}

out_sink_emit :: proc(d: rawptr, b: []u8) -> bool {
	s := (^Out_Stream)(d)
	return out_stream_bytes(s, b)
}

out_stream_writer :: proc(s: ^Out_Stream) -> io.Writer {
	stream_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		st := (^Out_Stream)(data)
		#partial switch mode {
		case .Query:
			return io.query_utility({.Write, .Flush})
		case .Write:
			if !out_stream_write(st, p) {
				return 0, st.io_err if st.io_err != .None else io.Error.Unexpected_EOF
			}
			return i64(len(p)), .None
		case .Flush:
			if !out_stream_flush(st) {
				return 0, st.io_err if st.io_err != .None else io.Error.Unexpected_EOF
			}
			return 0, .None
		}
		return 0, .Empty
	}
	return io.Writer{procedure = stream_proc, data = s}
}

out_stream_bytes :: proc(s: ^Out_Stream, data: []u8) -> bool {
	return out_stream_write(s, data) && (!s.unbuffered || out_stream_flush(s))
}

out_stream_bytes_nl :: proc(s: ^Out_Stream, data: []u8) -> bool {
	if !out_stream_write(s, data) {
		return false
	}
	if len(data) == 0 || data[len(data) - 1] != '\n' {
		nl := [1]u8{'\n'}
		if !out_stream_write(s, nl[:]) {
			return false
		}
	}
	return !s.unbuffered || out_stream_flush(s)
}

report_stdout_error :: proc(stderr_w: io.Writer, err: io.Error) -> int {
	if stderr_w.procedure != nil {
		if err != .None {
			fmt.wprintf(stderr_w, "stury: error: writing output failed: %v\n", err)
		} else {
			fmt.wprintln(stderr_w, "stury: error: writing output failed")
		}
	}
	return EXIT_USAGE
}

report_out_stream_error :: proc(osink: ^Out_Stream, stderr_w: io.Writer) -> int {
	if osink != nil && !osink.reported {
		osink.reported = true
		return report_stdout_error(stderr_w, osink.io_err)
	}
	return EXIT_USAGE
}

report_stdout_os_error :: proc(stderr_w: io.Writer, err: os.Error) -> int {
	if stderr_w.procedure != nil {
		if err != nil {
			fmt.wprintf(stderr_w, "stury: error: writing output failed: %s\n", os.error_string(err))
		} else {
			fmt.wprintln(stderr_w, "stury: error: writing output failed")
		}
	}
	return EXIT_USAGE
}

// Resolves input `(spec, framing)` without sniffing invalid JSON as CSV/JSON5.
detect_file_spec :: proc(o: ^Options, path: string) -> (engine.Spec, engine.Framing) {
	sp, fr := engine.spec_of_id(.Json), engine.Framing.Single
	if o.has_from {
		sp = o.from_spec
		fr = .Seq if (o.seq && o.from_framing == .Single) else o.from_framing
	} else if o.seq {
		fr = .Seq
	} else if path != "-" && path != "" {
		if e, ffr, ok := engine.format_of_path(path); ok {
			sp, fr = e.spec, ffr
		}
	}
	if o.merge_keys && sp == engine.spec_of_id(.Yaml) {
		sp = engine.spec_of_id(.Yaml_Merge)
	}
	return sp, fr
}

// Attaches format-specific read options strictly to matching format families.
read_opts_of :: proc(o: ^Options, sp: engine.Spec, runner: ^tape.Runner) -> tape.Options {
	ro := tape.Options{budget = o.budget, dups = o.dups, runner = runner}
	e, ok := engine.entry_of_spec(sp)
	if !ok {
		return ro
	}
	#partial switch e.family {
	case .Dsv:
		if o.dsv_in_set || o.infer { ro.format = o.dsv_in }
		ro.tolerate = o.dsv_tolerate
	case .Xml:
		xo := tape.Xml_Options{infer = o.infer, arrays = .Always if o.xml_arrays == .Always else .Auto}
		if xo.infer || xo.arrays != .Auto { ro.format = xo }
		ro.tolerate = o.xml_tolerate
	case .Yaml:
		if o.yaml_schema_set { ro.format = tape.Yaml_Options{dialect = o.yaml_schema} }
	}
	return ro
}

print_located_error :: proc(stderr_w: io.Writer, prefix, file: string, src: []u8, off: u64, msg: string, binary := false) {
	if stderr_w.procedure == nil {
		return
	}
	pl := tape.offset_place(src, nil, min(off, u64(len(src))))
	if !binary && len(src) > 0 {
		snip_buf: [1024]u8
		if snip, has_snip := tape.error_snippet(snip_buf[:], src, min(off, u64(len(src)))); has_snip {
			fmt.wprintf(stderr_w, "%s: %s:%d:%d: %s\n%s", prefix, file, pl.line, pl.col, msg, snip)
			return
		}
	}
	fmt.wprintf(stderr_w, "%s: %s:%d:%d: %s\n", prefix, file, pl.line, pl.col, msg)
}

tape_error_parts :: proc(src: []u8, err: tape.Error, sp: engine.Spec, err_buf: ^[512]u8, note_buf: ^[1024]u8) -> (at: u64, msg, note: string, has_place: bool) {
	e, _ := engine.entry_of_spec(sp)
	at = tape.NO_BYTE
	if f, is_f := err.(tape.Fault); is_f {
		at, has_place = f.at, f.at != tape.NO_BYTE
		msg = fault_sentence(err_buf[:], f, src, e.format)
	} else if ex, is_ex := err.(tape.Exceeded); is_ex {
		at, has_place = ex.at, ex.at != tape.NO_BYTE
		msg = exceeded_sentence(ex.kind)
	} else if bo, is_bo := err.(tape.Bad_Option); is_bo {
		msg = fmt.bprintf(err_buf[:], "invalid option: %s", bo.option)
		return
	} else {
		msg = "parse error"
		return
	}
	if has_place && !e.binary && len(src) > 0 {
		if snip, ok := tape.error_snippet(note_buf[:], src, at); ok {
			note = snip
		}
	}
	return
}

@(private = "file")
exceeded_sentence :: proc "contextless" (kind: tape.Budget_Kind) -> string {
	#partial switch kind {
	case .Depth:     return "Value nests deeper than limit"
	case .Nodes:     return "Too many nodes"
	case .Memory:    return "Exceeds memory limit"
	case .Steps:     return "Exceeds step limit"
	case .Expansion: return "Exceeds the expansion limit"
	}
	return "Exceeds limit"
}

@(private = "file")
fault_sentence :: proc(buf: []u8, f: tape.Fault, src: []u8, fmt_ptr: ^tape.Format) -> string {
	full := tape.error_message(buf, f, src, fmt_ptr)
	if f.at == tape.NO_BYTE || full == "" {
		return full if full != "" else "parse error"
	}
	if colon1 := strings.index_byte(full, ':'); colon1 >= 0 {
		rest := full[colon1 + 1:]
		if colon2 := strings.index_byte(rest, ':'); colon2 >= 0 {
			if trimmed := strings.trim_left_space(rest[colon2 + 1:]); trimmed != "" {
				return trimmed
			}
		}
	}
	return full
}

print_tape_error :: proc(
	stderr_w: io.Writer,
	file: string,
	err: tape.Error,
	src: []u8,
	sp: engine.Spec,
	ignoring := false,
	place_src: []u8 = nil,
	place_off: u64 = 0,
) -> int {
	if stderr_w.procedure == nil {
		return EXIT_RUNTIME
	}
	err_buf: [512]u8
	e, _ := engine.entry_of_spec(sp)
	prefix := "stury: ignoring parse error" if ignoring else "stury: parse error"
	psrc := place_src if len(place_src) > 0 else src
	msg_src := src if len(src) > 0 else psrc
	at, sent := tape.NO_BYTE, ""
	if f, is_f := err.(tape.Fault); is_f && f.at != tape.NO_BYTE {
		at, sent = f.at, fault_sentence(err_buf[:], f, msg_src, e.format)
	} else if ex, is_ex := err.(tape.Exceeded); is_ex && ex.at != tape.NO_BYTE {
		at, sent = ex.at, exceeded_sentence(ex.kind)
	}
	if at != tape.NO_BYTE && !e.binary && len(psrc) > 0 {
		print_located_error(stderr_w, prefix, file, psrc, place_off + at, sent)
		return EXIT_RUNTIME
	}
	msg := tape.error_message(err_buf[:], err, msg_src, e.format)
	fmt.wprintf(stderr_w, "%s (%s): %s\n", prefix, file, msg if msg != "" else "parse error")
	return EXIT_RUNTIME
}

// Atomic temp-file write + sync + close + rename. When `preserve_mode` is true, `path` must already exist as a regular file.
@(private = "file")
atomic_write_impl :: proc(path: string, data: []u8, preserve_mode: bool, tmp_prefix: string, alloc: runtime.Allocator) -> os.Error {
	fmode: os.Permissions
	if info, lerr := os.lstat(path, alloc); lerr == nil {
		ftype := info.type
		fmode = info.mode
		os.file_info_delete(info, alloc)
		if ftype != .Regular {
			return os.General_Error.Invalid_File
		}
	} else if preserve_mode || (lerr != os.General_Error.Not_Exist && lerr != .Not_Exist) {
		return lerr
	}

	dir := os.dir(path)
	if dir == "" { dir = "." }
	f: ^os.File
	tmp: string
	err: os.Error
	digits: [24]u8
	perm := os.Permissions{.Read_User, .Write_User} if preserve_mode else os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}
	for _ in 0 ..< 64 {
		rv: u64
		runtime.rand_bytes((^[8]u8)(&rv)[:])
		tmp = strings.concatenate({dir, "/", tmp_prefix, strconv.write_uint(digits[:], rv, 10), ".tmp"}, alloc)
		f, err = os.open(tmp, {.Read, .Write, .Create, .Excl}, perm)
		if err != os.General_Error.Exist && err != .Exist {
			break
		}
		delete(tmp, alloc)
		tmp = ""
	}
	if err != nil || f == nil {
		if tmp != "" { delete(tmp, alloc) }
		return err
	}
	defer delete(tmp, alloc)
	if n, werr := os.write(f, data); werr != nil {
		err = werr
	} else if n < len(data) {
		err = io.Error.Short_Write
	}
	if err == nil && preserve_mode {
		if cerr := os.fchmod(f, fmode); cerr != nil { err = cerr }
	}
	if err == nil {
		if syerr := os.sync(f); syerr != nil && syerr != io.Error.Unsupported { err = syerr }
	}
	if close_err := os.close(f); err == nil && close_err != nil { err = close_err }
	if err == nil { err = os.rename(tmp, path) }
	if err != nil { _ = os.remove(tmp) }
	return err
}

atomic_write_file :: proc(path: string, data: []u8, alloc: runtime.Allocator) -> os.Error {
	return atomic_write_impl(path, data, true, ".stury-", alloc)
}

write_plan_pin_file :: proc(path: string, data: []u8, stderr_w: io.Writer, alloc: runtime.Allocator) -> bool {
	if path == "/dev/stdout" || path == "/dev/stderr" {
		target := os.stdout if path == "/dev/stdout" else os.stderr
		n, werr := os.write(target, data)
		if werr != nil || n < len(data) {
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: Could not write plan file %s: %s\n", path, os.error_string(werr) if werr != nil else "short write")
			}
			return false
		}
		return true
	}
	if err := atomic_write_impl(path, data, false, ".stury-plan-", alloc); err != nil {
		if stderr_w.procedure != nil {
			if err == os.General_Error.Invalid_File {
				fmt.wprintf(stderr_w, "stury: error: Could not write plan file %s: not a regular file\n", path)
			} else {
				fmt.wprintf(stderr_w, "stury: error: Could not write plan file %s: %s\n", path, os.error_string(err))
			}
		}
		return false
	}
	return true
}

Plan_Pin_State :: struct {
	has_expected: bool,
	expected:     engine.Plan_Pin,
	out_path:     string,
	written:      bool,
	alloc:        runtime.Allocator,
}

plan_pin_init :: proc(ps: ^Plan_Pin_State, o: ^Options, stderr_w: io.Writer, alloc: runtime.Allocator) -> bool {
	ps^ = {out_path = o.plan_out, alloc = alloc}
	if o.plan_file == "" {
		return true
	}
	raw, rok := read_path_or_stdin(o.plan_file, false, stderr_w, alloc)
	if !rok { return false }
	defer delete(raw, alloc)
	pin, pok := engine.parse_plan_pin_json(string(raw), alloc)
	if !pok {
		if stderr_w.procedure != nil {
			fmt.wprintf(stderr_w, "stury: error: invalid plan file %s\n", o.plan_file)
		}
		return false
	}
	ps.expected, ps.has_expected = pin, true
	return true
}

plan_pin_destroy :: proc(ps: ^Plan_Pin_State) {
	if ps == nil { return }
	if ps.has_expected { engine.destroy_plan_pin(&ps.expected, ps.alloc) }
	ps^ = {}
}

plan_pin_apply :: proc(ps: ^Plan_Pin_State, dec: ^engine.Decision, stderr_w: io.Writer, alloc: runtime.Allocator) -> int {
	if ps == nil || dec == nil { return EXIT_OK }
	if ps.has_expected {
		diff_sb := strings.builder_make(alloc)
		defer strings.builder_destroy(&diff_sb)
		if !engine.compare_plan_pin(ps.expected, engine.plan_pin_of(dec), &diff_sb) {
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: plan mismatch: %s\n", strings.to_string(diff_sb))
			}
			return EXIT_FALSY
		}
	}
	if ps.out_path != "" && !ps.written {
		pin_json := engine.explain_pin_json(dec, alloc)
		defer delete(pin_json, alloc)
		if !write_plan_pin_file(ps.out_path, transmute([]u8)pin_json, stderr_w, alloc) {
			return EXIT_USAGE
		}
		ps.written = true
	}
	return EXIT_OK
}

// Persistent record-iterator wrapping `tape.records_find` cleanly across a buffer slice.
Rec_Loop :: struct {
	recs:     ^tape.Records,
	src:      []u8,
	sp:       engine.Spec,
	display:  string,
	stderr_w: io.Writer,
	buf:      [64]tape.Record,
	ans:      [64]tape.Span_Answer,
	n, i:     int,
	open_err: tape.Error,
	tail_err: tape.Error,
	alloc:    runtime.Allocator,
}

rec_loop_open :: proc(src: []u8, sp: engine.Spec, fr: engine.Framing, ro: tape.Options, skip_bad: bool, display: string, stderr_w: io.Writer, alloc: runtime.Allocator) -> (Rec_Loop, bool) {
	tf, _ := engine.to_tape_framing(fr)
	recs, rerr := engine.records_open(src, sp, tf, ro, nil, alloc)
	if rerr != nil {
		if stderr_w.procedure != nil {
			_ = print_tape_error(stderr_w, display, rerr, src, sp)
		}
		return {open_err = rerr}, false
	}
	recs.skip_bad = skip_bad
	return {recs = recs, src = src, sp = sp, display = display, stderr_w = stderr_w, alloc = alloc}, true
}

rec_loop_next :: proc(it: ^Rec_Loop) -> (rec: []u8, rinfo: tape.Record, err: tape.Error, has: bool) {
	if it.recs == nil { return nil, {}, nil, false }
	if it.i >= it.n {
		it.i = 0
		it.n = tape.records_find(it.recs, nil, it.buf[:], it.ans[:], {}, it.alloc)
		if it.n == 0 {
			it.tail_err = it.recs.err
			if it.tail_err != nil && it.stderr_w.procedure != nil {
				_ = print_tape_error(it.stderr_w, it.display, it.tail_err, it.src, it.sp)
			}
			return nil, {}, nil, false
		}
	}
	r := it.buf[it.i]
	it.i += 1
	return it.src[r.lo:r.hi], r, r.err, true
}

rec_loop_close :: proc(it: ^Rec_Loop) {
	if it.recs != nil {
		tape.destroy_records(it.recs)
		it.recs = nil
	}
}

@(private = "file")
open_readable_file :: proc(path: string, allow_stdin: bool, stderr_w: io.Writer, alloc: runtime.Allocator) -> (f: ^os.File, close_f: bool, size_hint: int, ok: bool) {
	if allow_stdin && path == "-" {
		f = os.stdin
	} else {
		ferr: os.Error
		f, ferr = os.open(path)
		if ferr != nil {
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: Could not open %s: %s\n", path, os.error_string(ferr))
			}
			return nil, false, 0, false
		}
		close_f = true
	}
	if fi, serr := os.fstat(f, alloc); serr == nil {
		defer os.file_info_delete(fi, alloc)
		if fi.type == .Directory {
			if close_f { os.close(f) }
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: %s: Is a directory\n", path)
			}
			return nil, false, 0, false
		}
		if fi.type == .Regular && fi.size > 0 && fi.size < i64(1 << 30) {
			size_hint = int(fi.size)
		}
	}
	return f, close_f, size_hint, true
}

// Streaming byte source for a single path or stdin.
Byte_Stream :: struct {
	file:       ^os.File,
	close_file: bool,
	mem_buf:    []u8,
	mem_off:    int,
	buf:        [dynamic]u8,
	off:        int,
	eof:        bool,
	err:        os.Error,
	alloc:      runtime.Allocator,
}

byte_stream_open :: proc(path: string, stdin_override: Maybe([]u8), stderr_w: io.Writer, alloc: runtime.Allocator) -> (bs: Byte_Stream, ok: bool) {
	if path == "-" {
		if data, has_mem := stdin_override.?; has_mem {
			return {mem_buf = data, eof = true, alloc = alloc}, true
		}
		return {file = os.stdin, buf = make([dynamic]u8, 0, 64 * 1024, alloc), alloc = alloc}, true
	}
	f, close_f, _, fok := open_readable_file(path, false, stderr_w, alloc)
	if !fok { return {}, false }
	return {file = f, close_file = close_f, buf = make([dynamic]u8, 0, 64 * 1024, alloc), alloc = alloc}, true
}

byte_stream_close :: proc(bs: ^Byte_Stream) {
	if bs.close_file && bs.file != nil {
		os.close(bs.file)
		bs.file, bs.close_file = nil, false
	}
	delete(bs.buf)
	bs.buf = nil
}

@(private = "file")
byte_stream_unread :: proc(bs: ^Byte_Stream) -> []u8 {
	return bs.mem_buf[bs.mem_off:] if bs.file == nil else bs.buf[bs.off:]
}

@(private = "file")
byte_stream_consume :: proc(bs: ^Byte_Stream, n: int) {
	if bs.file == nil {
		bs.mem_off += n
		return
	}
	bs.off += n
	if bs.off >= 32 * 1024 || bs.off == len(bs.buf) {
		rem := len(bs.buf) - bs.off
		if rem > 0 { copy(bs.buf[:rem], bs.buf[bs.off:]) }
		resize(&bs.buf, rem)
		bs.off = 0
	}
}

@(private = "file")
byte_stream_fill :: proc(bs: ^Byte_Stream) -> bool {
	if bs.eof || bs.file == nil { return false }
	chunk: [65536]u8
	n, err := os.read(bs.file, chunk[:])
	if n > 0 {
		append(&bs.buf, ..chunk[:n])
		return true
	}
	if err != nil && err != io.Error.EOF && err != os.General_Error.Broken_Pipe {
		bs.err = err
	}
	bs.eof = true
	return false
}

byte_stream_next_raw_line :: proc(bs: ^Byte_Stream, line_out: ^string) -> (has: bool, had_nl: bool, err: os.Error) {
	for {
		rem := byte_stream_unread(bs)
		for b, i in rem {
			if b == '\n' {
				line_out^ = string(rem[:i - 1 if (i > 0 && rem[i - 1] == '\r') else i])
				byte_stream_consume(bs, i + 1)
				return true, true, nil
			}
		}
		if !byte_stream_fill(bs) {
			if bs.err != nil { return false, false, bs.err }
			rem = byte_stream_unread(bs)
			if len(rem) == 0 { return false, false, nil }
			line_out^ = string(rem)
			byte_stream_consume(bs, len(rem))
			return true, false, nil
		}
	}
}

// Reads next LF- or RS-bounded span for streaming NDJSON/`.Seq` in bounded O(record) memory.
byte_stream_next_delim_span :: proc(bs: ^Byte_Stream, delim: u8, span_out: ^[]u8, copy_buf: ^[dynamic]u8, skip_blank_leading := false) -> (has: bool, had_delim: bool, err: os.Error) {
	take_span :: proc(bs: ^Byte_Stream, copy_buf: ^[dynamic]u8, span_out: ^[]u8, data: []u8, consume: int) {
		clear(copy_buf)
		append(copy_buf, ..data)
		span_out^ = copy_buf[:]
		byte_stream_consume(bs, consume)
	}
	for {
		rem := byte_stream_unread(bs)
		if skip_blank_leading {
			ws := 0
			for ws < len(rem) && (rem[ws] == ' ' || rem[ws] == '\t' || rem[ws] == '\r' || rem[ws] == '\n') { ws += 1 }
			if ws > 0 { byte_stream_consume(bs, ws); rem = byte_stream_unread(bs) }
		}
		if len(rem) > 0 {
			if delim == '\n' {
				for b, i in rem {
					if b == '\n' {
						take_span(bs, copy_buf, span_out, rem[:i - 1 if (i > 0 && rem[i - 1] == '\r') else i], i + 1)
						return true, true, nil
					}
				}
				if bs.eof {
					take_span(bs, copy_buf, span_out, rem, len(rem))
					return true, false, nil
				}
			} else {
				has_rs := rem[0] == delim
				if has_rs {
					for len(rem) > 1 && rem[1] == delim {
						byte_stream_consume(bs, 1)
						rem = byte_stream_unread(bs)
					}
				}
				start := 1 if has_rs else 0
				for i := start; i < len(rem); i += 1 {
					if rem[i] == delim {
						take_span(bs, copy_buf, span_out, rem[start:i], i)
						return true, has_rs, nil
					}
				}
				if bs.eof {
					if has_rs && len(rem) == 1 {
						byte_stream_consume(bs, 1)
						return false, false, nil
					}
					take_span(bs, copy_buf, span_out, rem[start:], len(rem))
					return true, has_rs, nil
				}
			}
		}
		if !byte_stream_fill(bs) {
			if bs.err != nil { return false, false, bs.err }
			if len(byte_stream_unread(bs)) == 0 { return false, false, nil }
		}
	}
}

read_path_or_stdin :: proc(path: string, allow_stdin: bool, stderr_w: io.Writer, alloc: runtime.Allocator) -> ([]u8, bool) {
	f, close_f, size_hint, ok := open_readable_file(path, allow_stdin, stderr_w, alloc)
	if !ok { return nil, false }
	defer if close_f { os.close(f) }

	buf := make([dynamic]u8, 0, size_hint if size_hint > 0 else 4096, alloc)
	chunk: [65536]u8
	for {
		n, err := os.read(f, chunk[:])
		if n > 0 { append(&buf, ..chunk[:n]) }
		if err != nil {
			if err == io.Error.EOF || err == os.General_Error.Broken_Pipe { break }
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: Could not read %s: %s\n", path, os.error_string(err))
			}
			delete(buf)
			return nil, false
		}
		if n == 0 { break }
	}
	return buf[:], true
}

read_input_bytes :: proc(path: string, stdin_override: Maybe([]u8), stderr_w: io.Writer, alloc: runtime.Allocator) -> (data: []u8, owned: bool, ok: bool) {
	if path == "-" {
		if sb, has := stdin_override.?; has { return sb, false, true }
	}
	b, rok := read_path_or_stdin(path, true, stderr_w, alloc)
	return b, rok, rok
}

preflight_in_place :: proc(o: ^Options, check_same_to: bool, stderr_w: io.Writer, alloc: runtime.Allocator) -> bool {
	if !o.in_place { return true }
	for p in o.files {
		info, lerr := os.lstat(p, alloc)
		if lerr != nil {
			fmt.wprintf(stderr_w, "stury: error: Could not stat %s: %s\n", p, os.error_string(lerr))
			return false
		}
		t := info.type
		os.file_info_delete(info, alloc)
		if t != .Regular {
			fmt.wprintf(stderr_w, "stury: error: %s: not a regular file (refusing --in-place on symlink or special file)\n", p)
			return false
		}
		if check_same_to && o.has_to {
			if sp, _ := detect_file_spec(o, p); o.to_spec != sp {
				fmt.wprintf(stderr_w, "stury: --in-place cannot combine with --to %s on %s\n", o.to_name, p)
				return false
			}
		}
	}
	return true
}

// Lazy cross-platform local timezone cache initialized on first timezone lookup.
Zone_Cache :: struct {
	lock:  sync.Mutex,
	names: [dynamic]string,
	alloc: runtime.Allocator,
}

zone_cache_init :: proc(zc: ^Zone_Cache, alloc: runtime.Allocator) {
	zc^ = {alloc = alloc}
	zc.names.allocator = alloc
}

zone_cache_destroy :: proc(zc: ^Zone_Cache) {
	if zc == nil { return }
	for s in zc.names { delete(s, zc.alloc) }
	delete(zc.names)
	zc^ = {}
}

@(private = "file")
intern_zone_name_locked :: proc(zc: ^Zone_Cache, raw: string) -> string {
	for s in zc.names {
		if s == raw { return s }
	}
	c := strings.clone(raw, zc.alloc)
	append(&zc.names, c)
	return c
}

when ODIN_OS == .Windows {
	foreign import win_ucrt "system:libucrt.lib"
	@(default_calling_convention = "c")
	foreign win_ucrt {
		@(link_name = "_localtime64_s")
		win_localtime64_s :: proc(tm_out: ^libc.tm, timer: ^libc.time_t) -> i32 ---
	}
	@(private = "file")
	floor_div_i64 :: proc "contextless" (a, b: i64) -> i64 {
		q := a / b
		return q - 1 if (a % b != 0 && (a < 0) != (b < 0)) else q
	}
	@(private = "file")
	floor_mod_i64 :: proc "contextless" (a, b: i64) -> i64 {
		m := a % b
		return m + b if m < 0 else m
	}
	@(private = "file")
	civil_to_unix :: proc "contextless" (y, m, d, hr, mn, sc: i64) -> i64 {
		y2 := y - 1 if m <= 2 else y
		era := floor_div_i64(y2, 400)
		yoe := y2 - era * 400
		doy := (153 * (m - 3 if m > 2 else m + 9) + 2) / 5 + d - 1
		return (era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468) * 86400 + hr * 3600 + mn * 60 + sc
	}
	@(private = "file")
	unix_to_civil :: proc "contextless" (secs: i64) -> (y, m, d, hr, mn, sc: i64) {
		z := floor_div_i64(secs, 86400)
		rem := secs - z * 86400
		hr, mn, sc = rem / 3600, (rem % 3600) / 60, rem % 60
		z += 719468
		era := floor_div_i64(z, 146097)
		doe := z - era * 146097
		yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
		y = yoe + era * 400
		doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
		mp := (5 * doy + 2) / 153
		d = doy - (153 * mp + 2) / 5 + 1
		m = mp + (3 if mp < 10 else -9)
		if m <= 2 { y += 1 }
		return
	}
} else {
	when ODIN_OS == .Darwin {
		foreign import pos_libc "system:System"
	} else {
		foreign import pos_libc "system:c"
	}
	when ODIN_OS == .NetBSD {
		@(private = "file")
		LLOCALTIME_R :: "__localtime_r50"
	} else {
		@(private = "file")
		LLOCALTIME_R :: "localtime_r"
	}
	@(default_calling_convention = "c")
	foreign pos_libc {
		@(link_name = LLOCALTIME_R)
		posix_localtime_r :: proc(timer: ^libc.time_t, result: ^libc.tm) -> ^libc.tm ---
	}
}

local_zone_at :: proc(data: rawptr, secs: i64) -> (query.Zone, bool) {
	zc := (^Zone_Cache)(data)
	if zc == nil { return {offset = 0, name = "UTC"}, true }
	sync.mutex_guard(&zc.lock)
	when ODIN_OS == .Windows {
		WIN_MAX_TIME :: i64(32535215999)
		query_secs := secs
		if query_secs < 0 || query_secs > WIN_MAX_TIME {
			y, m, d, hr, mn, sc := unix_to_civil(secs)
			is_leap := y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
			jan1_wd := floor_mod_i64(floor_div_i64(civil_to_unix(y, 1, 1, 0, 0, 0), 86400) + 4, 7)
			eq_y := i64(1996)
			for cand := i64(1996); cand <= 2023; cand += 1 {
				if (cand % 4 == 0) == is_leap && floor_mod_i64(floor_div_i64(civil_to_unix(cand, 1, 1, 0, 0, 0), 86400) + 4, 7) == jan1_wd {
					eq_y = cand
					break
				}
			}
			query_secs = civil_to_unix(eq_y, m, d, hr, mn, sc)
		}
		t := libc.time_t(query_secs)
		tm_buf: libc.tm
		if win_localtime64_s(&tm_buf, &t) != 0 { return {}, false }
		local_secs := civil_to_unix(i64(tm_buf.tm_year) + 1900, i64(tm_buf.tm_mon) + 1, i64(tm_buf.tm_mday), i64(tm_buf.tm_hour), i64(tm_buf.tm_min), i64(tm_buf.tm_sec))
		zbuf: [64]u8
		zn := int(libc.strftime(raw_data(zbuf[:]), len(zbuf), "%Z", &tm_buf))
		zstr := intern_zone_name_locked(zc, string(zbuf[:zn])) if zn > 0 else "UTC"
		return {offset = local_secs - query_secs, name = zstr}, true
	} else {
		t := libc.time_t(secs)
		tm_buf: libc.tm
		if posix_localtime_r(&t, &tm_buf) == nil { return {}, false }
		zstr := "UTC"
		if tm_buf.tm_zone != nil {
			if zs := string(cstring(tm_buf.tm_zone)); zs != "" {
				zstr = intern_zone_name_locked(zc, zs)
			}
		}
		return {offset = i64(tm_buf.tm_gmtoff), name = zstr}, true
	}
}

count_newlines :: proc "contextless" (b: []u8) -> i64 {
	n := i64(0)
	for c in b {
		if c == '\n' { n += 1 }
	}
	return n
}
