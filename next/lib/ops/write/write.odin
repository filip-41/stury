package write

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "stury:lib/core/tape"

// Writes of a built document as a text or binary encoding of a format, plus streaming token writers and table/Markdown
// renderers. A format gives its grammar and spelling: its layout loop over the steps `tree_next` gives, or for a
// delimited format the rules of its cells, and how it spells a scalar. This package holds what every format shares: the
// walk over a document's values, the output buffer, the text of a node, token sequences, and which facts a write drops.
// A format forwards the write under its own name (`json.write`, `dsv.write`, `cbor.write`, ...).

// Options of a write of any format.
Options :: struct {
	// A delimited token writer's column names, in the order they are written, nil for the first row's keys.
	// `Bad_Option{"header"}` under `grow_header` or when a key repeats.
	header:      []string,
	// The value written as a text of its own, the root by default. A key is no value, and `Bad_Option{"node"}`.
	node:        tape.Node_Index,
	// The target's own options, as a read takes them: `Dsv_Options` for delimited formats or `Yaml_Options` for YAML.
	// Nil takes those a delimited document was read with, else the target's defaults. Another family's options are
	// `Bad_Option{"format"}`.
	format:      tape.Format_Options,
	// Spaces a level, one value or member a line. 0 with `tab` false is compact text. When both `indent > 0` and
	// `tab` are set, `tab` takes precedence in JSON, XML, HTML and TOML; YAML uses spaces (tabs are forbidden there).
	indent:      u8,
	tab:         bool, // a tab a level in place of `indent` spaces
	// An object's members in the order of their keys' texts, byte by byte, and a table's columns by their names.
	sort_keys:   bool,
	// A JSON, YAML or HTML target spells each character past ASCII as an escape (`\u` / surrogate pair or `&#NNN;`).
	ascii:       bool,
	// Each value written is a record of its own: a line (NDJSON, a compact text only) or an RFC 7464 sequence's, which
	// starts with a record separator and ends with a line feed. A token writer takes any number of root values then.
	framing:     Record_Framing,
	// A delimited token writer holds every row and writes the header of every key in first-seen order at its end. Without
	// it the header is the caller's, else the first row's keys, rows are written as they come, and a later row's key the
	// header lacks is `Refused{.Row_Keys}`. A write of a document writes the union of its keys either way.
	grow_header: bool,
}

when size_of(int) == 8 {
	#assert(size_of(Options) == 32)
}

// How a text of values frames each one, as `Options.framing` says.
Record_Framing :: enum u8 {
	None,
	Lines,
	Seq,
}

// Why a write refused a value, which `Refused` names with its node.
Refusal :: enum u8 {
	// The target has no spelling that reads back as the value: a non-finite number in JSON, a byte string, a key that
	// is a container, a number wider than 64 bits with no decimal text, a cell a delimited spec cannot hold.
	No_Spelling,
	// A delimited target takes an array of rows, each an object of scalars or an array of scalars.
	Not_A_Table,
	// A row's keys do not match the header (caller-supplied or first row's), or a headerless array row's width differs.
	Row_Keys,
	// A container a path read kept only part of, or that a text cut inside its root left open, which would be written
	// as less than the text holds. A text cut inside a scalar root is this refusal at the root.
	Partial,
	// A token the sequence cannot take at that place, or one that opens past the depth a caller holds, with the index
	// of the token as `node`.
	Malformed,
}

// A value the target cannot write as the document holds it, and the node it is.
Refused :: struct {
	node: tape.Node_Index,
	why:  Refusal,
}

// The error of a write. A sink's failure is its `io.Error`, and the sink may hold a prefix of the text.
Error :: union {
	Refused,
	runtime.Allocator_Error,
	io.Error,
	tape.Bad_Option,
}

// Whether `opts` asks for compact text.
@(require_results)
compact :: #force_inline proc "contextless" (opts: Options) -> bool {
	return opts.indent == 0 && !opts.tab
}

// The bytes a target text of `doc` under `opts` is likely to need, which a buffer output starts with, so a write seldom
// grows it: the source's length (or subtree span when `opts.node != ROOT`), the room a write of whole blocks asks for
// past its last byte, and in indented text a capped indent estimate per node.
@(private, require_results)
size_hint :: proc "contextless" (doc: ^tape.Document, opts: Options) -> int {
	if len(doc.nodes) == 0 || u64(opts.node) >= u64(len(doc.nodes)) {
		return 0
	}
	src := u64(len(doc.src))
	nodes := u64(len(doc.nodes))
	if opts.node != tape.ROOT {
		t := doc.nodes[opts.node]
		nodes = u64(tape.node_after(doc, opts.node) - opts.node)
		if t.kind < .Array {
			src = u64(t.n)
		} else {
			last := doc.nodes[opts.node + tape.Node_Index(nodes) - 1]
			tail := u64(last.n) if last.kind < .Array else 0
			if .Held not_in doc.flags && last.lo >= t.lo && last.lo + tail <= u64(len(doc.src)) {
				src = last.lo + tail - t.lo
			} else {
				src = min(src, nodes * 16)
			}
		}
	}
	est := src + ROOM_MAX
	if !compact(opts) {
		// Cap the upfront indent multiplier so large `opts.indent` (up to 255) never requests gigabytes upfront.
		unit := u64(1) if opts.tab else min(u64(opts.indent), 8)
		est += nodes * (3 + 8 * unit)
	}
	return int(min(est, u64(max(int) / 2)))
}

// The output a writer spells into: a buffer from the caller's allocator that doubles as it fills, or a buffer of
// `SINK_BYTES` written to the caller's sink whenever it fills. A writer asks `room` for bytes, writes them and moves
// `cursor`, and the one branch in `room` leads to the cold proc that grows or flushes.

// The most bytes one `room` call may ask for. A writer with more writes them in pieces.
ROOM_MAX :: 4096

// The buffer a sink's output holds before it writes to the sink.
SINK_BYTES :: 64 * 1024

#assert(ROOM_MAX > 0 && SINK_BYTES >= ROOM_MAX)

// An output, which must have been started cleanly via `out_start` and is not copied once `out_start` returns. After a
// refused allocation or a failed sink, `room` hands back the start of the buffer it holds, whose bytes nobody reads,
// so a writer checks `err` only where it can stop.
Out :: struct {
	buf:       [^]u8,
	size:      int, // the bytes `buf` holds
	cursor:    int, // the bytes written into `buf` and not yet flushed
	sink:      io.Writer, // a nil procedure for a buffer output
	allocator: runtime.Allocator,
	err:       Error, // the first failure, kept
}

when size_of(int) == 8 {
	#assert(size_of(Out) == 80)
}

// The format's write of value `opts.node` of `doc` as a text of `spec` into `out`, returning the fact kinds dropped.
@(private)
Write_Out :: #type proc(out: ^Out, doc: ^tape.Document, spec: u8, opts: Options, allocator: runtime.Allocator) -> (tape.Facts, Error)

// Writes by the format's `write_out` in a buffer from `allocator` that the caller owns and frees with it, which a
// format's `write` forwards to. On an error there is no text and no fact is dropped.
@(require_results)
to_buffer :: proc(doc: ^tape.Document, spec: u8, opts: Options, allocator: runtime.Allocator, write_out: Write_Out) -> (text: []u8, dropped: tape.Facts, err: Error) {
	return run_out({}, doc, spec, opts, allocator, write_out)
}

// `to_buffer` into `sink`, through a buffer of `SINK_BYTES` from `allocator`, which a format's `write_to` forwards to.
// A sink with no procedure is `Bad_Option{"sink"}`. On a refusal or a failed sink the sink may hold a prefix of the
// text.
@(require_results)
to_sink :: proc(sink: io.Writer, doc: ^tape.Document, spec: u8, opts: Options, allocator: runtime.Allocator, write_out: Write_Out) -> (dropped: tape.Facts, err: Error) {
	if sink.procedure == nil {
		return {}, tape.Bad_Option{"sink"}
	}
	_, dropped, err = run_out(sink, doc, spec, opts, allocator, write_out)
	return
}

@(private = "file", require_results)
run_out :: #force_inline proc(sink: io.Writer, doc: ^tape.Document, spec: u8, opts: Options, allocator: runtime.Allocator, write_out: Write_Out) -> (text: []u8, dropped: tape.Facts, err: Error) {
	out: Out
	hint := 0 if sink.procedure != nil else size_hint(doc, opts)
	if e := out_start(&out, allocator, sink, hint); e != nil {
		return nil, {}, e
	}
	if dropped, err = write_out(&out, doc, spec, opts, allocator); err != nil {
		out_drop(&out)
		return nil, {}, err
	}
	if text, err = out_finish(&out); err != nil {
		dropped = {}
	}
	return
}

// Starts an output into a buffer of at least `hint` bytes, or into `sink` when it has a procedure. It allocates its
// buffer here, so a refusal is the error and no writer runs.
@(require_results)
out_start :: proc(out: ^Out, allocator: runtime.Allocator, sink: io.Writer, hint: int) -> runtime.Allocator_Error {
	out^ = {sink = sink, allocator = allocator}
	size := SINK_BYTES if sink.procedure != nil else max(hint, ROOM_MAX)
	raw := alloc_bytes(size, 1, allocator) or_return
	out.buf, out.size = raw_data(raw), size
	return nil
}

// `size` bytes from `allocator`, not zeroed, `.Out_Of_Memory` from an allocator that gives fewer.
@(private, require_results)
alloc_bytes :: proc(size, align: int, allocator: runtime.Allocator) -> ([]u8, runtime.Allocator_Error) {
	raw, err := runtime.mem_alloc_non_zeroed(size, align, allocator)
	if err == nil && (raw_data(raw) == nil || len(raw) < size) {
		err = .Out_Of_Memory
	}
	return raw, err
}

// Doubles `stack`, of `held` items, of which the first `inline` are the caller's own and stay unfreed. False with
// `err` set when memory is refused.
@(cold, require_results)
grow_stack :: #force_no_inline proc(stack: ^[^]$T, held: ^int, inline: int, allocator: runtime.Allocator, err: ^Error) -> bool {
	if held^ <= 0 || held^ > max(int) / (2 * size_of(T)) {
		err^ = .Out_Of_Memory
		return false
	}
	raw, e := alloc_bytes(2 * held^ * size_of(T), align_of(T), allocator)
	if e != nil {
		err^ = e
		return false
	}
	grown := ([^]T)(raw_data(raw))
	intrinsics.mem_copy_non_overlapping(grown, stack^, held^ * size_of(T))
	free_stack(stack^, held^, inline, allocator)
	stack^, held^ = grown, 2 * held^
	return true
}

// Frees a stack `grow_stack` grew past the caller's own `inline` items.
free_stack :: proc(stack: [^]$T, held, inline: int, allocator: runtime.Allocator) {
	if held > inline {
		runtime.mem_free_with_size(stack, held * size_of(T), allocator)
	}
}

// At least `n` free bytes at the cursor, `n` at most `ROOM_MAX`. The caller writes up to `n` bytes there and moves
// `cursor` past them. Invariant: `out_start` succeeded, so `out.buf != nil && out.size >= ROOM_MAX`.
room :: #force_inline proc(out: ^Out, n: int) -> [^]u8 #no_bounds_check {
	if out.size - out.cursor < n {
		return refill(out, n)
	}
	return out.buf[out.cursor:]
}

// Writes `b`, of any length, at the cursor.
put :: #force_inline proc(out: ^Out, b: []u8) {
	if len(b) <= ROOM_MAX {
		p := room(out, len(b))
		intrinsics.mem_copy_non_overlapping(p, raw_data(b), len(b))
		out.cursor += len(b)
		return
	}
	put_long(out, b)
}

// Writes the byte `c` at the cursor.
put_byte :: #force_inline proc(out: ^Out, c: u8) #no_bounds_check {
	room(out, 1)[0] = c
	out.cursor += 1
}

// Writes a line end followed by `level * width` indent bytes filled from the repeated-byte word `fill`.
line_indent :: #force_inline proc(out: ^Out, width: int, fill: u64, level: int) #no_bounds_check {
	n := level * width
	if n + 9 > ROOM_MAX {
		line_indent_long(out, fill, n)
		return
	}
	p := room(out, n + 9)
	p[0] = '\n'
	for k := 0; k < n; k += 8 {
		intrinsics.unaligned_store((^u64)(p[1 + k:]), fill)
	}
	out.cursor += n + 1
}

@(private = "file", cold)
line_indent_long :: #force_no_inline proc(out: ^Out, fill: u64, n: int) {
	put_byte(out, '\n')
	for left := n; left > 0; {
		k := min(left, ROOM_MAX - 8)
		p := room(out, k + 8)
		for i := 0; i < k; i += 8 {
			intrinsics.unaligned_store((^u64)(p[i:]), fill)
		}
		out.cursor += k
		left -= k
	}
}

// Whether the object at `at` holds a `#text` member, so that no whitespace may be added between its children.
holds_text :: proc(w: ^Tree, at: tape.Node_Index, markup: bool, text_key := "#text") -> bool {
	end := tape.node_after(w.doc, at)
	for k := at + 1; k < end; k = tape.node_after(w.doc, k + 1) {
		if markup {
			if tape.is_text_key(w.nodes[k]) {
				return true
			}
			continue
		}
		if t := w.nodes[k]; t.spelling & tape.SPELLING_DECODE == 0 && int(t.n) != len(text_key) {
			continue
		}
		if name, ok := text_of(w, k); ok && name == text_key {
			return true
		}
	}
	return false
}

// Writes what a sink output holds to the sink now, so a writer that sizes its runs by the room left starts them in a
// whole buffer. A buffer output is untouched.
drain :: proc(out: ^Out) {
	if out.sink.procedure != nil && out.err == nil && out.cursor > 0 {
		flush(out)
	}
}

// Ends the output. A buffer output returns its bytes (or `nil, nil` when empty), which the caller owns and frees with
// the allocator it gave (note: the returned slice's backing block may exceed `len(text)`), or nil and the error. A sink
// output writes what it holds to the sink and returns no bytes. Either zeroes `out` and is not used again.
@(require_results)
out_finish :: proc(out: ^Out) -> (text: []u8, err: Error) {
	if out.sink.procedure != nil {
		if out.err == nil && out.cursor > 0 {
			flush(out)
		}
		err = out.err
		out_drop(out)
		return nil, err
	}
	if out.err != nil {
		err = out.err
		out_drop(out)
		return nil, err
	}
	if out.cursor == 0 {
		out_drop(out)
		return nil, nil
	}
	text = out.buf[:out.cursor]
	out^ = {}
	return text, nil
}

// Frees an output that `out_finish` did not end, for a writer that stops on a refusal.
out_drop :: proc(out: ^Out) {
	runtime.mem_free_with_size(out.buf, out.size, out.allocator)
	out^ = {}
}

@(private = "file")
put_long :: #force_no_inline proc(out: ^Out, b: []u8) {
	if out.err != nil {
		return
	}
	if out.size - out.cursor >= len(b) {
		intrinsics.mem_copy_non_overlapping(out.buf[out.cursor:], raw_data(b), len(b))
		out.cursor += len(b)
		return
	}
	for left := b; len(left) > 0 && out.err == nil; {
		k := min(ROOM_MAX, len(left))
		intrinsics.mem_copy_non_overlapping(room(out, k), raw_data(left), k)
		out.cursor += k
		left = left[k:]
	}
}

// The cold side of `room`: the buffer is written to the sink, or else doubled. After a failure the buffer is scratch.
@(private = "file", cold)
refill :: #force_no_inline proc(out: ^Out, n: int) -> [^]u8 {
	assert(n <= ROOM_MAX, "room asked for more than ROOM_MAX")
	if out.err != nil {
		out.cursor = 0
		return out.buf
	}
	if out.sink.procedure != nil {
		flush(out)
		return out.buf
	}
	if n > max(int) - out.cursor {
		out.err = .Out_Of_Memory
		out.cursor = 0
		return out.buf
	}
	need := out.cursor + n
	size := max(2 * out.size, need) if out.size <= max(int) / 2 else need
	raw, err := runtime.non_zero_mem_resize(out.buf, out.size, size, 1, out.allocator)
	if err == nil && (raw_data(raw) == nil || len(raw) < size) {
		err = .Out_Of_Memory
	}
	if err != nil {
		out.err = err
		out.cursor = 0
		return out.buf
	}
	out.buf, out.size = raw_data(raw), size
	return out.buf[out.cursor:]
}

// Writes the buffer to the sink and empties it, again from where the sink stopped while it takes bytes. A sink that
// takes none and names no error is `.Short_Write`, and one that says it took more than it was given `.Invalid_Write`.
@(private = "file")
flush :: proc(out: ^Out) {
	left := out.buf[:out.cursor]
	out.cursor = 0
	for len(left) > 0 {
		wrote, err := io.write(out.sink, left)
		if err == .None && wrote <= 0 {
			err = .Short_Write
		}
		if err == .None && wrote > len(left) {
			err = .Invalid_Write
		}
		if err != .None {
			out.err = err
			return
		}
		left = left[wrote:]
	}
}
