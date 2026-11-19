package toml

// The typed read and write of TOML: `unmarshal` reads the table tree into a value, through the document route of
// `core/typed`, and `marshal` writes a value by the token write. A key is compared by its decoded text.

import "base:runtime"
import core "../core"
import typed "../core/typed"
import write "../core/write"

// Reads `src`, a TOML text of `spec`, into `target`. An absent member keeps what `target` holds. A datetime is read into a
// string as its text. The form with no plan builds one with `context.allocator` and frees it before it returns, and a plan
// built once with `plan_make` is the form for many reads. A refusal leaves everything the read allocated reachable from
// `target`.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Writes `value` as TOML into new bytes from `allocator`, as `write` says: a struct or map as a table, a nested one as a
// section, a list of them as an array of tables. The form with no plan builds and frees one for the call, and a plan from
// `plan_make` is the form for many writes.
marshal :: proc {marshal_once, write.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Toml_1_0, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	nothing: any
	v := typed.marshal_target(value, &nothing)
	plan, refusal := plan_make(v.id, spec, opts)
	return typed.marshal_planned(&plan, refusal, v.data, write, allocator)
}

// Returns the typed reads of `spec`, which `plan_make` takes for a plan that reads a text through
// `typed.unmarshal_text`.
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return reads_of(.Toml_1_1) if S == .Toml_1_1 else reads_of(.Toml_1_0)
}

// Returns the checks of `spec` read with `opts`, which `model.compile` and `schema.bind` take: the reads, which check a
// text or a document by a plan made from a description or a model, and the handle its plans read by, which reaches no
// service.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {reads(S), bound_as(S, opts)}
}

// Builds the plan of `T` for TOML, as `typed.plan_make` does. A plan of either spec writes TOML 1.0 forms, and reads a
// document through `typed.unmarshal`. It reads a text only with `reads`, and with none it reads through `unmarshal`.
plan_make :: proc(T: typeid, spec := Spec.Toml_1_0, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, reads, allocator)
	return made, core.error_of(err)
}

// The plan of `T` over `READERS`, with TOML's writer and document read, and the reads `reads` holds.
@(private)
plan_built :: proc(T: typeid, spec: Spec, opts: Options, plan: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, bound_as(spec, opts), plan, allocator)
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, err
}

// Gives a plan TOML's writer, token writer, check of a `Raw` member's text and document read.
@(private)
plan_bind :: proc(p: ^typed.Plan) {
	p.marshal, p.raw, p.tokens, p.value_text = marshal_text, edit_value, &TOKENS, write.value_text
	p.node_read, p.node_check = typed.read_nodes, typed.check_nodes
}

// The handle's `plans`: the plan takes its reads, the check of a `Raw` member and the token writer from the handle's
// services.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as, opts, allocator)
	p.marshal, p.value_text = marshal_text, write.value_text
	return p, err
}

// The typed reads of a plan read as spec `S`: a text's tree is replayed to the reader, and a document's nodes are read by
// the generic route, which compares a key by its decoded text.
@(private)
reads_of :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	@(static, rodata) r := typed.Format_Reads {
		read       = text_read,
		check      = text_check,
		node_read  = typed.read_nodes,
		node_check = typed.check_nodes,
		build      = build_text,
		plan       = proc(T: typeid, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {return plan_built(T, S, {}, opts, reads_of(S), allocator)},
	}
	return &r
}

// The read the replay of a text's tree gives the reader's hook, and the tree for a union's tag.
@(private)
Tree_Read :: struct {
	reader: typed.Reader,
	parser: ^Parser,
	replay: ^Replay,
	last:   u64, // one past the last value given, or a container's first byte when it holds none yet
}

// Reads `src` into `target` by replaying its table tree to the reader's hook, with no document. The text is read whole
// first, since a table's members may be written apart.
@(private)
text_read :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	if as.spec > u8(max(Spec)) {
		return {kind = .Bad_Option}
	}
	read := read
	if read.dups == .Refuse {
		// A repeated key is a fault of the text, so no read meets one to refuse.
		read.dups = .Last
	}
	frames: [core.MAX_DEPTH + 2]typed.Frame = ---
	h: Tree_Read
	regs, started := typed.read_start(&h.reader, src, plan, as, T, target, read, frames[:], allocator, false)
	if started.kind != .None {
		return started
	}
	defer typed.read_release(&h.reader, frames[:])
	limit := depth_limit(options_of(as))
	if int(limit) + 2 > len(frames) {
		if _, grown := typed.grow_frames(&h.reader, len(frames), int(limit) + 2); !grown {
			return {kind = .No_Memory}
		}
	}
	p: Parser
	defer parser_destroy(&p)
	if !parser_init(&p, src, Spec(as.spec) == .Toml_1_1, limit) {
		return {kind = .No_Memory}
	}
	if !parse(&p, 0) {
		_, fault, _ := core.result_of(p.fail, &RULES)
		return typed.read_end(&h.reader, regs, fault)
	}
	s: Replay
	defer delete(s.frames)
	h.parser, h.replay = &p, &s
	h.reader.format, h.reader.find_tag = &h, tree_tag
	_, fault, _ := core.result_of(replay(&p, &s, &h, &regs, tree_step), &RULES)
	return typed.read_end(&h.reader, regs, fault)
}

// A token as the reader's hook takes it: a number's digits folded, and a close at the last byte of the container's
// last value, which is where the end of a table that has no bracket of its own is read.
@(private)
tree_step :: proc "contextless" (h: ^Tree_Read, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	t := t
	if t.role == .Value {
		#partial switch t.kind {
		case .End:
			t.lo, t.n = (t.lo if h.replay.id == 0 else h.last) - 1, 1
		case .Object, .Array:
			h.last = t.lo
		case .Number:
			if t.spelling & core.NUMBER_KIND_MASK == 0 {
				h.reader.mant = typed.fold_digits(h.reader.src, t)
			}
			h.last = t.lo + u64(t.n)
		case:
			h.last = t.lo + u64(t.n)
		}
	}
	return typed.on_token_spelled(&h.reader, regs, t)
}

// The reader's `find_tag`: the member `name` of the table the replay has just opened.
@(private)
tree_tag :: proc(r: ^typed.Reader, _: u64, name: string) -> typed.Tag_Scan {
	h := (^Tree_Read)(r.format)
	s := typed.Tag_Scan{view = {src = r.src, as = r.plan.as}, name = name}
	if id := find_child(&h.parser.tree, h.replay.id, name); id != NIL {
		s.found, s.value = 1, h.parser.tree.nodes[id].value
	}
	return s
}

@(private)
text_check :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return typed.check_built_text(src, as, build_handle, target, T, plan, read, allocator)
}

@(private)
unmarshal_once :: proc(src: []u8, $S: Spec, target: ^$T, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	plan, refusal := plan_make(T, S, opts)
	if refusal != nil {
		return refusal
	}
	defer typed.plan_destroy(&plan)
	err := text_read(src, bound_as(S, opts), target, T, &plan, read, allocator)
	typed.own_errors(&err, read.sink)
	return core.error_of(err)
}

@(private)
unmarshal_plan :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, opts := Options{}, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(text_read(src, bound_as(S, opts), target, T, plan, read, allocator))
}

// Reads `src` into `target` by `plan` as `unmarshal` does, with every refusal in `read.sink.entries`, and returns the
// first. The options are the plan's, and any plan of the format reads.
check :: proc(src: []u8, $S: Spec, target: ^$T, plan: ^typed.Plan, read := typed.Read_Options{}, allocator := context.allocator) -> core.Error {
	return typed.check_by(src, bound_as(S, options_of(typed.handle_of(plan))), target, T, plan, read, allocator, text_check)
}
