package cli

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import "stury:engine"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/query"

EXIT_OK :: 0
EXIT_FALSY :: 1
EXIT_USAGE :: 2
EXIT_COMPILE :: 3
EXIT_NO_OUTPUT :: 4
EXIT_RUNTIME :: 5

Input_File :: struct {
	path:    string,
	display: string,
	bytes:   []u8,
	spec:    engine.Spec,
	framing: engine.Framing,
	owned:   bool,
}

// Buffered streaming sink writing in fixed 64 KiB (`write.SINK_BYTES`) chunks with `--unbuffered`,
// `--each` line prefixing (with optional color), and write/flush error tracking.
Out_Stream :: struct {
	w:             io.Writer,
	buf:           [write.SINK_BYTES]u8,
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
			s.failed = true
			s.io_err = err
			return false
		}
		left = left[wrote:]
	}
	if !s.no_io_flush {
		if f, ok := io.to_flusher(s.w); ok {
			if ferr := io.flush(f); ferr != .None {
				s.failed = true
				s.io_err = ferr
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
	rem := p
	for len(rem) > 0 {
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
				s.failed = true
				s.io_err = err
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

out_stream_write_label :: proc(s: ^Out_Stream) -> bool {
	if s.color_label {
		if !out_stream_write_raw(s, transmute([]u8)string("\e[35m")) {
			return false
		}
		if !out_stream_write_raw(s, transmute([]u8)s.file_label) {
			return false
		}
		if !out_stream_write_raw(s, transmute([]u8)string("\e[0m:")) {
			return false
		}
		return true
	}
	if !out_stream_write_raw(s, transmute([]u8)s.file_label) {
		return false
	}
	return out_stream_write_raw(s, transmute([]u8)string(":"))
}

out_stream_write :: proc(s: ^Out_Stream, b: []u8) -> bool {
	if s.failed {
		return false
	}
	if s.file_label == "" {
		if !out_stream_write_raw(s, b) {
			return false
		}
	} else {
		from := 0
		for ch, i in b {
			if !s.open_line {
				if i > from && !out_stream_write_raw(s, b[from:i]) {
					return false
				}
				if !out_stream_write_label(s) {
					return false
				}
				from = i
				s.open_line = true
			}
			s.open_line = ch != '\n'
		}
		if len(b) > from && !out_stream_write_raw(s, b[from:]) {
			return false
		}
	}
	return true
}

out_stream_end_emit :: proc(s: ^Out_Stream, _: u8) -> bool {
	if s.unbuffered {
		return out_stream_flush(s)
	}
	return true
}

out_sink_emit :: proc(d: rawptr, b: []u8) -> bool {
	s := (^Out_Stream)(d)
	if !out_stream_write(s, b) {
		return false
	}
	last := b[len(b) - 1] if len(b) > 0 else u8(0)
	return out_stream_end_emit(s, last)
}

out_stream_writer :: proc(s: ^Out_Stream) -> io.Writer {
	stream_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, _: i64, _: io.Seek_From) -> (i64, io.Error) {
		st := (^Out_Stream)(data)
		#partial switch mode {
		case .Query:
			return io.query_utility({.Write, .Flush})
		case .Write:
			if !out_stream_write(st, p) {
				err := st.io_err if st.io_err != .None else io.Error.Unexpected_EOF
				return 0, err
			}
			return i64(len(p)), .None
		case .Flush:
			if !out_stream_flush(st) {
				err := st.io_err if st.io_err != .None else io.Error.Unexpected_EOF
				return 0, err
			}
			return 0, .None
		}
		return 0, .Empty
	}
	return io.Writer{procedure = stream_proc, data = s}
}

out_stream_bytes :: proc(s: ^Out_Stream, data: []u8) -> bool {
	if !out_stream_write(s, data) {
		return false
	}
	if s.unbuffered {
		return out_stream_flush(s)
	}
	return true
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
	if s.unbuffered {
		return out_stream_flush(s)
	}
	return true
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
	if o.has_from {
		fr := engine.Framing.Seq if (o.seq && o.from_framing == .Single) else o.from_framing
		return o.from_spec, fr
	}
	if o.seq {
		return engine.spec_of_id(.Json), .Seq
	}
	if path != "-" && path != "" {
		if e, fr, ok := engine.format_of_path(path); ok {
			return e.spec, fr
		}
	}
	return engine.spec_of_id(.Json), .Single
}

// Attaches format-specific read options strictly to matching format families.
read_opts_of :: proc(o: ^Options, sp: engine.Spec, runner: ^tape.Runner) -> tape.Options {
	ro := tape.Options{
		budget = o.budget,
		dups   = o.dups,
		runner = runner,
	}
	e, ok := engine.entry_of_spec(sp)
	if !ok {
		return ro
	}
	#partial switch e.family {
	case .Dsv:
		if o.dsv_in_set || o.infer {
			ro.format = o.dsv_in
		}
		ro.tolerate = o.dsv_tolerate
	case .Xml:
		if o.infer {
			ro.format = tape.Xml_Options{infer = true}
		}
		ro.tolerate = o.xml_tolerate
	}
	return ro
}

tape_error_parts :: proc(src: []u8, err: tape.Error, sp: engine.Spec, err_buf: ^[512]u8, note_buf: ^[256]u8) -> (at: u64, msg, note: string, has_place: bool) {
	e, _ := engine.entry_of_spec(sp)
	if f, is_f := err.(tape.Fault); is_f {
		at = f.at
		has_place = f.at != tape.NO_BYTE
		msg = fault_sentence(err_buf[:], f, src, e.format)
		if has_place && len(src) > 0 {
			note = fault_caret_note(note_buf[:], src, f.at)
		}
		return
	}
	if ex, is_ex := err.(tape.Exceeded); is_ex {
		at = ex.at
		has_place = ex.at != tape.NO_BYTE
		msg = "Exceeds limit"
		#partial switch ex.kind {
		case .Depth:
			msg = "Value nests deeper than limit"
		case .Nodes:
			msg = "Too many nodes"
		case .Memory:
			msg = "Exceeds memory limit"
		case .Steps:
			msg = "Exceeds step limit"
		case .Expansion:
			msg = "Exceeds the expansion limit"
		}
		if has_place && len(src) > 0 {
			note = fault_caret_note(note_buf[:], src, ex.at)
		}
		return
	}
	msg = "parse error"
	if bo, is_bo := err.(tape.Bad_Option); is_bo {
		msg = fmt.bprintf(err_buf[:], "invalid option: %s", bo.option)
	}
	return
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
			trimmed := strings.trim_left_space(rest[colon2 + 1:])
			if trimmed != "" {
				return trimmed
			}
		}
	}
	return full
}

@(private = "file")
fault_caret_note :: proc(buf: []u8, src: []u8, offset: u64) -> string {
	NOTE_REACH :: 40
	at := min(int(offset), len(src))
	if at == len(src) && at > 0 && src[at - 1] == '\n' {
		at -= 1
	}
	first, last := at, at
	for first > 0 && src[first - 1] != '\n' && at - first < NOTE_REACH {
		first -= 1
	}
	for last < len(src) && src[last] != '\n' && src[last] != '\r' && last - at < NOTE_REACH {
		last += 1
	}
	line_len := last - first
	pad_len := at - first
	n := 0
	for i in 0 ..< line_len {
		if n >= len(buf) {
			break
		}
		c := src[first + i]
		buf[n] = ' ' if (c < 0x20 && c != '\t' || c == 0x7f) else c
		n += 1
	}
	if n < len(buf) {
		buf[n] = '\n'
		n += 1
	}
	for i in 0 ..< pad_len {
		if n >= len(buf) {
			break
		}
		c := src[first + i]
		buf[n] = '\t' if c == '\t' else ' '
		n += 1
	}
	if n + 2 <= len(buf) {
		buf[n] = '^'
		buf[n + 1] = '\n'
		n += 2
	}
	return string(buf[:n])
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
	note_buf: [256]u8
	e, _ := engine.entry_of_spec(sp)
	prefix := "stury: ignoring parse error" if ignoring else "stury: parse error"
	psrc := place_src if len(place_src) > 0 else src
	if f, is_f := err.(tape.Fault); is_f && f.at != tape.NO_BYTE && !e.binary && len(psrc) > 0 {
		off := min(place_off + f.at, u64(len(psrc)))
		lidx := tape.Line_Index{allocator = runtime.heap_allocator()}
		defer tape.destroy_line_index(&lidx)
		pl := tape.offset_place(psrc, &lidx, off, 0, 1, runtime.heap_allocator())
		sent := fault_sentence(err_buf[:], f, psrc, e.format)
		note := fault_caret_note(note_buf[:], psrc, off)
		fmt.wprintf(stderr_w, "%s: %s:%d:%d: %s\n%s", prefix, file, pl.line, pl.col, sent, note)
		return EXIT_RUNTIME
	}
	msg := tape.error_message(err_buf[:], err, psrc, e.format)
	fmt.wprintf(stderr_w, "%s (%s): %s\n", prefix, file, msg if msg != "" else "parse error")
	return EXIT_RUNTIME
}

// Persistent record-iterator wrapping `tape.records_find` cleanly across a buffer slice.
Rec_Loop :: struct {
	recs:               ^tape.Records,
	src:                []u8,
	sp:                 engine.Spec,
	display:            string,
	stderr_w:           io.Writer,
	buf:                [64]tape.Record,
	ans:                [64]tape.Span_Answer,
	n:                  int,
	i:                  int,
	open_err:           tape.Error,
	tail_err:           tape.Error,
	alloc:              runtime.Allocator,
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
	if it.recs == nil {
		return nil, {}, nil, false
	}
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

// Streaming byte source for a single path or stdin, reading chunks without buffering whole streams in RAM.
Byte_Stream :: struct {
	file:        ^os.File,
	close_file:  bool,
	mem_buf:     []u8,
	mem_off:     int,
	buf:         [dynamic]u8,
	off:         int,
	eof:         bool,
	err:         os.Error,
	alloc:       runtime.Allocator,
}

byte_stream_open :: proc(path: string, stdin_override: Maybe([]u8), stderr_w: io.Writer, alloc: runtime.Allocator) -> (bs: Byte_Stream, ok: bool) {
	if path == "-" {
		if data, has_mem := stdin_override.?; has_mem {
			return {mem_buf = data, eof = true, alloc = alloc}, true
		}
		return {file = os.stdin, buf = make([dynamic]u8, 0, 64 * 1024, alloc), alloc = alloc}, true
	}
	f, ferr := os.open(path)
	if ferr != nil {
		if stderr_w.procedure != nil {
			fmt.wprintf(stderr_w, "stury: error: Could not open %s: %s\n", path, os.error_string(ferr))
		}
		return {}, false
	}
	if fi, serr := os.fstat(f, alloc); serr == nil {
		defer os.file_info_delete(fi, alloc)
		if fi.type == .Directory {
			os.close(f)
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: %s: Is a directory\n", path)
			}
			return {}, false
		}
	}
	return {file = f, close_file = true, buf = make([dynamic]u8, 0, 64 * 1024, alloc), alloc = alloc}, true
}

byte_stream_close :: proc(bs: ^Byte_Stream) {
	if bs.close_file && bs.file != nil {
		os.close(bs.file)
		bs.file = nil
		bs.close_file = false
	}
	if bs.buf != nil {
		delete(bs.buf)
		bs.buf = nil
	}
}

@(private = "file")
byte_stream_unread :: proc(bs: ^Byte_Stream) -> []u8 {
	if bs.file == nil {
		return bs.mem_buf[bs.mem_off:]
	}
	return bs.buf[bs.off:]
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
		if rem > 0 {
			copy(bs.buf[:rem], bs.buf[bs.off:])
		}
		resize(&bs.buf, rem)
		bs.off = 0
	}
}

@(private = "file")
byte_stream_fill :: proc(bs: ^Byte_Stream) -> bool {
	if bs.eof || bs.file == nil {
		return false
	}
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

// Reads the next line (stripping trailing `\n` / `\r\n`) in O(line length) memory, reporting whether a newline was seen.
byte_stream_next_raw_line :: proc(bs: ^Byte_Stream, line_out: ^string) -> (has: bool, had_nl: bool, err: os.Error) {
	for {
		rem := byte_stream_unread(bs)
		for i := 0; i < len(rem); i += 1 {
			if rem[i] == '\n' {
				slice_end := i - 1 if (i > 0 && rem[i - 1] == '\r') else i
				line_out^ = string(rem[:slice_end])
				byte_stream_consume(bs, i + 1)
				return true, true, nil
			}
		}
		if !byte_stream_fill(bs) {
			if bs.err != nil {
				return false, false, bs.err
			}
			rem = byte_stream_unread(bs)
			if len(rem) == 0 {
				return false, false, nil
			}
			line_out^ = string(rem)
			byte_stream_consume(bs, len(rem))
			return true, false, nil
		}
	}
}

// Reads next LF- or RS-bounded span for streaming NDJSON/`.Seq` in bounded O(record) memory.
// Returns `span_out` backed by `buf` until the next call that consumes/compacts `bs`.
byte_stream_next_delim_span :: proc(bs: ^Byte_Stream, delim: u8, span_out: ^[]u8, copy_buf: ^[dynamic]u8, skip_blank_leading := false) -> (has: bool, had_delim: bool, err: os.Error) {
	for {
		rem := byte_stream_unread(bs)
		if skip_blank_leading {
			ws := 0
			for ws < len(rem) && (rem[ws] == ' ' || rem[ws] == '\t' || rem[ws] == '\r' || rem[ws] == '\n') {
				ws += 1
			}
			if ws > 0 {
				byte_stream_consume(bs, ws)
				rem = byte_stream_unread(bs)
			}
		}
		if delim == '\n' {
			for i := 0; i < len(rem); i += 1 {
				if rem[i] == '\n' {
					end := i - 1 if (i > 0 && rem[i - 1] == '\r') else i
					clear(copy_buf)
					append(copy_buf, ..rem[:end])
					span_out^ = copy_buf[:]
					byte_stream_consume(bs, i + 1)
					return true, true, nil
				}
			}
			if bs.eof && len(rem) > 0 {
				clear(copy_buf)
				append(copy_buf, ..rem)
				span_out^ = copy_buf[:]
				byte_stream_consume(bs, len(rem))
				return true, false, nil
			}
		} else if len(rem) > 0 && rem[0] == delim {
			// Skip consecutive empty RS delimiters, and consume a lone trailing RS right at EOF.
			for len(rem) > 1 && rem[1] == delim {
				byte_stream_consume(bs, 1)
				rem = byte_stream_unread(bs)
			}
			for i := 1; i < len(rem); i += 1 {
				if rem[i] == delim {
					clear(copy_buf)
					append(copy_buf, ..rem[1:i])
					span_out^ = copy_buf[:]
					byte_stream_consume(bs, i)
					return true, true, nil
				}
			}
			if bs.eof {
				if len(rem) == 1 {
					byte_stream_consume(bs, 1)
					return false, false, nil
				}
				clear(copy_buf)
				append(copy_buf, ..rem[1:])
				span_out^ = copy_buf[:]
				byte_stream_consume(bs, len(rem))
				return true, true, nil
			}
		} else if len(rem) > 0 {
			for i := 0; i < len(rem); i += 1 {
				if rem[i] == delim {
					clear(copy_buf)
					append(copy_buf, ..rem[:i])
					span_out^ = copy_buf[:]
					byte_stream_consume(bs, i)
					return true, false, nil
				}
			}
			if bs.eof {
				clear(copy_buf)
				append(copy_buf, ..rem)
				span_out^ = copy_buf[:]
				byte_stream_consume(bs, len(rem))
				return true, false, nil
			}
		}
		if !byte_stream_fill(bs) {
			if bs.err != nil {
				return false, false, bs.err
			}
			rem = byte_stream_unread(bs)
			if len(rem) == 0 {
				return false, false, nil
			}
			// Loop once more now that `bs.eof` is true to emit the final span cleanly.
		}
	}
}

read_path_or_stdin :: proc(path: string, allow_stdin: bool, stderr_w: io.Writer, alloc: runtime.Allocator) -> ([]u8, bool) {
	f: ^os.File
	ferr: os.Error
	if allow_stdin && path == "-" {
		f = os.stdin
	} else {
		f, ferr = os.open(path)
		if ferr != nil {
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: Could not open %s: %s\n", path, os.error_string(ferr))
			}
			return nil, false
		}
	}
	defer if !(allow_stdin && path == "-") {
		os.close(f)
	}
	init_cap := 4096
	if fi, serr := os.fstat(f, alloc); serr == nil {
		defer os.file_info_delete(fi, alloc)
		if fi.type == .Directory {
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: %s: Is a directory\n", path)
			}
			return nil, false
		}
		if fi.type == .Regular && fi.size > 0 && fi.size < i64(1 << 30) {
			init_cap = int(fi.size)
		}
	}
	buf := make([dynamic]u8, 0, init_cap, alloc)
	chunk: [65536]u8
	for {
		n, err := os.read(f, chunk[:])
		if n > 0 {
			append(&buf, ..chunk[:n])
		}
		if err != nil {
			if err == io.Error.EOF || err == os.General_Error.Broken_Pipe {
				break
			}
			if stderr_w.procedure != nil {
				fmt.wprintf(stderr_w, "stury: error: Could not read %s: %s\n", path, os.error_string(err))
			}
			delete(buf)
			return nil, false
		}
		if n == 0 {
			break
		}
	}
	return buf[:], true
}

read_input_bytes :: proc(path: string, stdin_override: Maybe([]u8), stderr_w: io.Writer, alloc: runtime.Allocator) -> (data: []u8, owned: bool, ok: bool) {
	if path == "-" {
		if sb, has := stdin_override.?; has {
			return sb, false, true
		}
	}
	b, rok := read_path_or_stdin(path, true, stderr_w, alloc)
	return b, rok, rok
}

// Preflights all `--in-place` targets before editing/writing ANY file: refuses symlinks/non-regular files and format mismatches.
preflight_in_place :: proc(o: ^Options, check_same_to: bool, stderr_w: io.Writer, alloc: runtime.Allocator) -> bool {
	if !o.in_place {
		return true
	}
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
			sp, _ := detect_file_spec(o, p)
			if o.to_spec != sp {
				fmt.wprintf(stderr_w, "stury: --in-place cannot combine with --to %s on %s\n", o.to_name, p)
				return false
			}
		}
	}
	return true
}

atomic_write_file :: proc(path: string, data: []u8, alloc: runtime.Allocator) -> os.Error {
	info, serr := os.lstat(path, alloc)
	if serr != nil {
		return serr
	}
	ftype := info.type
	fmode := info.mode
	os.file_info_delete(info, alloc)
	if ftype != .Regular {
		return os.General_Error.Invalid_File
	}
	dir := os.dir(path)
	if dir == "" {
		dir = "."
	}
	f: ^os.File
	tmp: string
	err: os.Error
	digits: [24]u8
	for _ in 0 ..< 64 {
		num := strconv.write_uint(digits[:], rand.uint64(), 10)
		tmp = strings.concatenate({dir, "/.stury-", num, ".tmp"}, alloc)
		f, err = os.open(tmp, {.Read, .Write, .Create, .Excl}, {.Read_User, .Write_User})
		if err != os.General_Error.Exist && err != .Exist {
			break
		}
		delete(tmp, alloc)
		tmp = ""
	}
	if err != nil || f == nil {
		if tmp != "" {
			delete(tmp, alloc)
		}
		return err
	}
	defer delete(tmp, alloc)
	if n, werr := os.write(f, data); werr != nil {
		err = werr
	} else if n < len(data) {
		err = io.Error.Short_Write
	}
	if err == nil {
		if cerr := os.fchmod(f, fmode); cerr != nil {
			err = cerr
		}
	}
	if err == nil {
		if syerr := os.sync(f); syerr != nil && syerr != io.Error.Unsupported {
			err = syerr
		}
	}
	if close_err := os.close(f); err == nil && close_err != nil {
		err = close_err
	}
	if err == nil {
		err = os.rename(tmp, path)
	}
	if err != nil {
		_ = os.remove(tmp)
	}
	return err
}

// Cross-platform local timezone cache loaded once per query/edit invocation.
Zone_Cache :: struct {
	region: ^datetime.TZ_Region,
	alloc:  runtime.Allocator,
}

zone_cache_init :: proc(zc: ^Zone_Cache, alloc: runtime.Allocator) {
	reg, ok := timezone.region_load("local", alloc)
	zc^ = {
		region = reg if ok else nil,
		alloc  = alloc,
	}
}

zone_cache_destroy :: proc(zc: ^Zone_Cache) {
	if zc != nil && zc.region != nil {
		timezone.region_destroy(zc.region, zc.alloc)
		zc.region = nil
	}
}

local_zone_at :: proc(data: rawptr, secs: i64) -> (query.Zone, bool) {
	zc := (^Zone_Cache)(data)
	if zc == nil || zc.region == nil {
		return {offset = 0, name = "UTC"}, true
	}
	tm := time.unix(secs, 0)
	utc_dt, ok1 := time.time_to_datetime(tm)
	if !ok1 {
		return {}, false
	}
	local_dt, ok2 := timezone.datetime_to_tz(utc_dt, zc.region)
	if !ok2 {
		return {}, false
	}
	local_dt_plain := local_dt
	local_dt_plain.tz = nil
	local_tm, ok3 := time.datetime_to_time(local_dt_plain)
	if !ok3 {
		return {}, false
	}
	offset := time.to_unix_seconds(local_tm) - secs
	utc_for_name := utc_dt
	utc_for_name.tz = zc.region
	short, ok4 := timezone.shortname(utc_for_name)
	return {offset = offset, name = short if ok4 else "UTC"}, true
}

count_newlines :: proc "contextless" (b: []u8) -> i64 {
	n := i64(0)
	for c in b {
		if c == '\n' {
			n += 1
		}
	}
	return n
}
