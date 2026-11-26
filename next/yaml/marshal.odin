package yaml

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/ops/write"

// Typed writes: an Odin value written directly as YAML by the plan a typed read of its type makes, so struct tags under
// `yaml` (else `stury`), enums, and `-` skips match `unmarshal`. Uses a direct streaming emitter into `write.Out`
// without allocating an intermediate `Token_Tape`, falling back to `Writer` only when `opts.sort_keys` is set.

// Writes `value`, of a type the plan takes, as a YAML text of `spec` under `opts` in a buffer from `allocator` that the
// caller owns. `plan` is the plan of `T` that `plan_make` made once for repeated writes, else nil.
marshal :: proc(value: ^$T, spec := Spec.Yaml_1_2, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> (text: []u8, err: Write_Error) {
	if opts.sort_keys {
		w: Writer
		if err = writer_start(&w, spec, opts, {}, allocator); err != nil {
			return nil, err
		}
		if err = marshal_into_writer(&w, value, T, plan, allocator); err != nil {
			writer_drop(&w)
			return nil, err
		}
		return writer_end(&w)
	}
	write_check(u8(spec), opts) or_return
	sw := Stream_Writer {
		pretty  = !write.compact(opts),
		step    = int(opts.indent) if opts.indent > 0 else 2,
		opts    = opts,
		dialect = write_dialect(opts),
	}
	sw.extra.allocator = allocator
	defer delete(sw.extra)
	if aerr := write.out_start(&sw.out, allocator, {}, 0); aerr != nil {
		return nil, aerr
	}
	if err = marshal_stream(&sw, value, T, plan, allocator); err != nil {
		write.out_drop(&sw.out)
		return nil, err
	}
	return write.out_finish(&sw.out)
}

// `marshal` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. On a refusal or a failed sink the
// sink may hold a prefix of the text.
marshal_to :: proc(sink: io.Writer, value: ^$T, spec := Spec.Yaml_1_2, opts := Write_Options{}, plan: ^Plan = nil, allocator := context.allocator) -> Write_Error {
	if sink.procedure == nil {
		return tape.Bad_Option{"sink"}
	}
	if opts.sort_keys {
		w: Writer
		if err := writer_start(&w, spec, opts, sink, allocator); err != nil {
			return err
		}
		if err := marshal_into_writer(&w, value, T, plan, allocator); err != nil {
			writer_drop(&w)
			return err
		}
		_, err := writer_end(&w)
		return err
	}
	write_check(u8(spec), opts) or_return
	sw := Stream_Writer {
		pretty  = !write.compact(opts),
		step    = int(opts.indent) if opts.indent > 0 else 2,
		opts    = opts,
		dialect = write_dialect(opts),
	}
	sw.extra.allocator = allocator
	defer delete(sw.extra)
	if err := write.out_start(&sw.out, allocator, sink, 0); err != nil {
		return err
	}
	if err := marshal_stream(&sw, value, T, plan, allocator); err != nil {
		write.out_drop(&sw.out)
		return err
	}
	_, err := write.out_finish(&sw.out)
	return err
}

@(private = "file")
marshal_into_writer :: proc(w: ^Writer, value: rawptr, T: typeid, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
	werr, err := typed.marshal(value, T, TAG, plan, w, token, allocator)
	if werr != nil {
		return werr
	}
	if err != nil {
		if memory, ok := err.(runtime.Allocator_Error); ok {
			return memory
		}
		bad, _ := err.(tape.Bad_Option)
		return bad
	}
	return nil
}

@(private = "file")
marshal_stream :: proc(sw: ^Stream_Writer, value: rawptr, T: typeid, plan: ^Plan, allocator: runtime.Allocator) -> Write_Error {
	werr, err := typed.marshal(value, T, TAG, plan, sw, stream_token, allocator)
	if werr != nil {
		return werr
	}
	if sw.out.err != nil {
		return sw.out.err
	}
	if err != nil {
		if memory, ok := err.(runtime.Allocator_Error); ok {
			return memory
		}
		bad, _ := err.(tape.Bad_Option)
		return bad
	}
	return nil
}

@(private = "file")
Stream_Frame :: struct {
	object:     bool,
	opened:     bool,
	compact:    bool,
	expect_val: bool,
	ind:        int,
	count:      int,
}

@(private = "file")
Stream_Writer :: struct {
	out:      write.Out,
	opts:     Write_Options,
	dialect:  tape.Yaml_Dialect,
	pretty:   bool,
	step:     int,
	frames:   [64]Stream_Frame,
	extra:    [dynamic]Stream_Frame,
	depth:    int,
	has_root: bool,
}

@(private = "file")
frame_top :: #force_inline proc "contextless" (sw: ^Stream_Writer) -> ^Stream_Frame #no_bounds_check {
	if sw.depth <= len(sw.frames) {
		return &sw.frames[sw.depth - 1]
	}
	return &sw.extra[sw.depth - len(sw.frames) - 1]
}

@(private = "file")
push_stream_frame :: #force_inline proc(sw: ^Stream_Writer, f: Stream_Frame) -> Write_Error #no_bounds_check {
	if sw.depth < len(sw.frames) {
		sw.frames[sw.depth] = f
		sw.depth += 1
		return nil
	}
	if _, err := append(&sw.extra, f); err != nil {
		return err
	}
	sw.depth += 1
	return nil
}

@(private = "file")
pop_stream_frame :: #force_inline proc(sw: ^Stream_Writer) -> Stream_Frame #no_bounds_check {
	sw.depth -= 1
	if sw.depth < len(sw.frames) {
		return sw.frames[sw.depth]
	}
	return pop(&sw.extra)
}

@(private = "file")
stream_key_write :: #force_inline proc(sw: ^Stream_Writer, key: string, flow: bool) -> (explicit: bool, err: Write_Error) {
	if !sw.opts.ascii && len(key) <= KEY_MAX && plainly_safe(key) && !reads_as_other(key) {
		put_str(&sw.out, key)
		return false, sw.out.err
	}
	explicit = len(key) > KEY_MAX
	if explicit {
		put_str(&sw.out, "? ")
	}
	shape, valid := shape_of(key, Place{flow = flow, key = true, ascii = sw.opts.ascii})
	if !valid {
		return false, write.Refused{0, .No_Spelling}
	}
	if shape == .Plain && explicit {
		shape = .Single
	}
	put_scalar(&sw.out, key, shape, sw.opts.ascii)
	return explicit, sw.out.err
}

@(private = "file")
stream_scalar_write :: #force_inline proc(sw: ^Stream_Writer, kind: Token_Kind, text: string, flow, block: bool, block_ind: int) -> (ended: bool, err: Write_Error) {
	if sw.dialect == .Failsafe && kind != .String {
		return false, write.Refused{0, .No_Spelling}
	}
	#partial switch kind {
	case .Null:
		put_str(&sw.out, "null")
	case .True:
		put_str(&sw.out, "true")
	case .False:
		put_str(&sw.out, "false")
	case .Number:
		switch text {
		case "NaN":
			if sw.dialect == .Json {
				return false, write.Refused{0, .No_Spelling}
			}
			put_str(&sw.out, ".nan")
		case "Inf", "+Inf":
			if sw.dialect == .Json {
				return false, write.Refused{0, .No_Spelling}
			}
			put_str(&sw.out, ".inf")
		case "-Inf":
			if sw.dialect == .Json {
				return false, write.Refused{0, .No_Spelling}
			}
			put_str(&sw.out, "-.inf")
		case:
			put_str(&sw.out, text)
		}
	case .String:
		if !sw.opts.ascii && plainly_safe(text) && !reads_as_other(text) {
			put_str(&sw.out, text)
		} else {
			shape, valid := shape_of(text, Place{flow = flow, block = block, ascii = sw.opts.ascii})
			if !valid {
				return false, write.Refused{0, .No_Spelling}
			}
			if shape == .Literal || shape == .Folded {
				put_block(&sw.out, text, shape, block_ind)
				return true, sw.out.err
			}
			put_scalar(&sw.out, text, shape, sw.opts.ascii)
		}
	case:
		return false, write.Refused{0, .No_Spelling}
	}
	return false, sw.out.err
}

@(private = "file")
stream_token :: proc(sw: ^Stream_Writer, kind: Token_Kind, text := "") -> Write_Error {
	if sw.out.err != nil {
		return sw.out.err
	}
	if kind == .Close {
		if sw.depth == 0 {
			return write.Refused{0, .Malformed}
		}
		f := pop_stream_frame(sw)
		if !sw.pretty {
			write.put_byte(&sw.out, '}' if f.object else ']')
			return sw.out.err
		}
		if !f.opened {
			if sw.depth > 0 {
				write.put_byte(&sw.out, ' ')
			}
			put_str(&sw.out, "{}\n" if f.object else "[]\n")
		}
		return sw.out.err
	}

	if sw.depth == 0 {
		if sw.has_root {
			return write.Refused{0, .Malformed}
		}
		sw.has_root = true
		if kind == .Object || kind == .Array {
			is_obj := kind == .Object
			if !sw.pretty {
				write.put_byte(&sw.out, '{' if is_obj else '[')
				return push_stream_frame(sw, Stream_Frame{object = is_obj, opened = true})
			}
			return push_stream_frame(sw, Stream_Frame{object = is_obj})
		}
		if kind == .Key {
			return write.Refused{0, .Malformed}
		}
		ended := stream_scalar_write(sw, kind, text, !sw.pretty, sw.pretty, sw.step) or_return
		if !ended && sw.pretty {
			write.put_byte(&sw.out, '\n')
		}
		return sw.out.err
	}

	p := frame_top(sw)
	if p.object {
		if kind == .Key {
			if p.expect_val {
				return write.Refused{0, .Malformed}
			}
			if !sw.pretty {
				if p.count > 0 {
					put_str(&sw.out, ", ")
				}
				explicit := stream_key_write(sw, text, true) or_return
				put_str(&sw.out, " : " if explicit else ": ")
				p.count += 1
				p.expect_val = true
				return sw.out.err
			}
			if !p.opened {
				if sw.depth > 1 {
					if p.compact {
						write.put_byte(&sw.out, ' ')
					} else {
						write.put_byte(&sw.out, '\n')
						put_run(&sw.out, p.ind, ' ')
					}
				}
				p.opened = true
			} else {
				put_run(&sw.out, p.ind, ' ')
			}
			explicit := stream_key_write(sw, text, false) or_return
			if explicit {
				write.put_byte(&sw.out, '\n')
				put_run(&sw.out, p.ind, ' ')
			}
			write.put_byte(&sw.out, ':')
			p.count += 1
			p.expect_val = true
			return sw.out.err
		}
		if !p.expect_val {
			return write.Refused{0, .Malformed}
		}
		p.expect_val = false
		child_ind := p.ind + sw.step
		if kind == .Object || kind == .Array {
			is_obj := kind == .Object
			if !sw.pretty {
				write.put_byte(&sw.out, '{' if is_obj else '[')
				return push_stream_frame(sw, Stream_Frame{object = is_obj, opened = true})
			}
			return push_stream_frame(sw, Stream_Frame{object = is_obj, ind = child_ind})
		}
		if sw.pretty {
			write.put_byte(&sw.out, ' ')
		}
		ended := stream_scalar_write(sw, kind, text, !sw.pretty, sw.pretty, child_ind) or_return
		if !ended && sw.pretty {
			write.put_byte(&sw.out, '\n')
		}
		return sw.out.err
	}

	if kind == .Key {
		return write.Refused{0, .Malformed}
	}
	if !sw.pretty {
		if p.count > 0 {
			put_str(&sw.out, ", ")
		}
		p.count += 1
		if kind == .Object || kind == .Array {
			is_obj := kind == .Object
			write.put_byte(&sw.out, '{' if is_obj else '[')
			return push_stream_frame(sw, Stream_Frame{object = is_obj, opened = true})
		}
		_, err := stream_scalar_write(sw, kind, text, true, false, 0)
		return err
	}

	if !p.opened {
		if sw.depth > 1 {
			if p.compact {
				write.put_byte(&sw.out, ' ')
			} else {
				write.put_byte(&sw.out, '\n')
				put_run(&sw.out, p.ind, ' ')
			}
		}
		p.opened = true
	} else {
		put_run(&sw.out, p.ind, ' ')
	}
	write.put_byte(&sw.out, '-')
	p.count += 1
	child_ind := p.ind + 2
	if kind == .Object || kind == .Array {
		return push_stream_frame(sw, Stream_Frame{object = kind == .Object, compact = true, ind = child_ind})
	}
	write.put_byte(&sw.out, ' ')
	ended := stream_scalar_write(sw, kind, text, false, true, child_ind) or_return
	if !ended {
		write.put_byte(&sw.out, '\n')
	}
	return sw.out.err
}
