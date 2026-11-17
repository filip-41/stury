package yaml

// The typed read and write of YAML: `unmarshal` reads a document into a value through the document route of
// `core/typed`, since an alias repeats its anchor's node. A field or a map key is named by a key's decoded text. Two
// keys of one text and two types are refused, except under `.First` and `.All`. A plain scalar is read as the core
// schema resolves it. `marshal` writes a value by the token write, as block style or, when the layout is compact, as
// one line of flow style.

import "base:runtime"
import "core:slice"
import "core:strings"
import spell "../core/spell"
import core "../core"
import rules "../core/rules"
import typed "../core/typed"
import cw "../core/write"

// Reads `src`, a YAML text of one document, into `target`. An absent member keeps what `target` holds. The form with
// no plan builds one with `context.allocator` and frees it before it returns, and a plan built once with `plan_make` is
// the form for many reads. A refusal leaves everything the read allocated reachable from `target`. `read.dups` picks
// among a repeated key as `json.unmarshal` does.
unmarshal :: proc {unmarshal_once, unmarshal_plan}

// Returns the typed reads of `spec`, which `plan_make` takes for a plan that reads through `typed.unmarshal_text`.
reads :: proc "contextless" ($S: Spec) -> ^typed.Format_Reads {
	return &READS
}

// Returns the checks of `spec` read with `opts`, which `model.compile` and `schema.bind` take: the reads of a plan made
// from a model or a description, and the handle of `spec` its plans read by.
checks :: proc "contextless" ($S: Spec, opts := Options{}) -> typed.Format_Checks {
	return {&CHECKS, bound_as(S, opts)}
}

// Builds the plan of `T` for YAML, as `typed.plan_make` does. The plan reads a text only with `reads`, and with none it
// reads through `unmarshal`.
plan_make :: proc(T: typeid, spec := Spec.Yaml_1_2, opts := Options{}, plan := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := plan_built(T, spec, opts, plan, reads, allocator)
	return made, core.error_of(err)
}

// Builds the plan that reads values of description `d` as `spec`, as `typed.plan_of` does. The reads are the plan's with
// `reads`, as for `plan_make`.
plan_of :: proc(d: ^rules.Description, spec := Spec.Yaml_1_2, opts := typed.Plan_Options{}, reads: ^typed.Format_Reads = nil, allocator := context.allocator) -> (typed.Plan, core.Error) {
	made, err := typed.plan_of(d, as_of(&PLAN_READERS, spec, {}), reads, opts, allocator)
	if err == nil {
		plan_bind(&made)
	}
	return made, err
}

// The plan of `T` with the writer, the token writer and the document read of YAML, and the reads `reads` holds.
@(private)
plan_built :: proc(T: typeid, spec: Spec, layout: Options, opts: typed.Plan_Options, reads: ^typed.Format_Reads, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as_of(&PLAN_READERS, spec, layout), opts, allocator)
	plan_bind(&p)
	typed.plan_reads(&p, reads)
	return p, err
}

// Gives a plan YAML's writer, token writer, document read and check of a `Raw` member's text.
@(private)
plan_bind :: proc(p: ^typed.Plan) {
	p.marshal, p.tokens, p.node_read, p.raw = marshal_text, &TOKENS, node_read, edit_value
	p.value_text = cw.value_text
}

// The handle's `plans`.
@(private)
plan_as :: proc(T: typeid, as: core.As, opts: typed.Plan_Options, allocator: runtime.Allocator) -> (typed.Plan, core.Typed_Refusal) {
	p, err := typed.plan_build(T, as, opts, allocator)
	plan_bind(&p)
	return p, err
}

// The read of a text. A plan whose members read only the tokens of their values reads during the walk, and any other
// plan, or a read that reports to a sink, reads the text's document, built under `.Refuse` refusing a repeated key, as
// `typed.read_nodes` reads it.
@(private)
text_read :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	if plan != nil && read.sink == nil && reads_tokens(plan) {
		return walk_read(src, as, target, T, plan, read, allocator)
	}
	return typed.read_built_text(src, as, typed_build, target, T, plan, read, allocator)
}

// Whether every member of `plan` is read from its value's tokens alone. A union that reads objects by a tag member
// finds it, a value read whole takes its text's ends, a required member and a fixed array name the byte of their
// container's close, and a byte string reads its tag, so those read the document.
@(private)
reads_tokens :: proc(plan: ^typed.Plan) -> bool {
	if plan.model_plan != .None || plan.checking {
		return false
	}
	for f in plan.fields {
		#partial switch f.kind {
		case .Union:
			if plan.meta[f.meta].tagged {
				return false
			}
		case .Required, .Array, .Before, .Any, .Hook, .Raw, .Value, .Checked, .Bytes:
			return false
		}
	}
	return true
}

// A typed read during the walk. Each plain value scalar takes the kind its tag and the core schema give it before the
// reader takes it, as `type_scalars` gives it in a document. The walk passes every token here, so the keys of the whole
// text are judged as a build judges them: while no key of the text resolves to no string, the keys of each open
// collection are only noted, and the first that does starts `keys`, which judges every key from then on, and from the
// start under `.Refuse`. A value the reader skips still passes here, and once the reader stops the walk goes on for
// the faults and the keys of the rest of the text, which come before the reader's refusal as in a read of a document.
@(private)
Walk_Read :: struct {
	reader:     typed.Reader,
	src:        []u8,
	room:       int, // the frames the reader holds
	tag:        core.Token, // the tag of the next node, when `tagged`
	tagged:     bool,
	skip:       u8, // 0 none, 1 passing a skipped key's value, 2 passing a skipped container
	skip_depth: u32,
	muted:      bool, // the reader stopped
	nodes:      int,
	refuse:     bool,
	typed_keys: bool, // a key of the text resolves to no string
	judging:    bool,
	keys:       Key_Table,
	// The keys of each open collection while `judging` is not set: collection `i` holds those of `noted` from
	// `opens[i].first` to the next one's.
	opens:      [dynamic]Noted_Open,
	noted:      [dynamic]core.Token,
	repeat:     u64, // the byte of the first repeat in the walk's order, 0 for none
	repeat_min: u64, // the lowest such byte
	clash:      u64,
	complex:    u64, // the first byte of a key that is a collection, when `found`
	found:      bool,
}

@(private)
Noted_Open :: struct {
	first:  u32,
	object: bool,
}

@(private)
walk_read :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	frames: [core.MAX_DEPTH + 2]typed.Frame = ---
	w: Walk_Read
	w.src, w.room = src, len(frames)
	w.refuse = read.dups == .Refuse
	w.judging = w.refuse
	w.repeat_min = max(u64)
	bound := read
	if bound.dups == .Refuse {
		bound.dups = .Last
	}
	regs, err := typed.read_start(&w.reader, src, plan, as, T, target, bound, frames[:], allocator, false)
	if err.kind != .None {
		return err
	}
	defer typed.read_release(&w.reader, frames[:])
	defer walk_read_destroy(&w)
	opts := options_of(as)
	hi, fault := walk_noting(src, 0, opts, &w, &regs, walk_read_hook, nil, nil, nil)
	f := Filter{complex = w.complex, found = w.found}
	fault = document_fault(src, hi, opts, &f, fault, u64(w.nodes))
	refused: core.Typed_Refusal
	bad, faulted := fault.?
	switch {
	case w.refuse && !w.typed_keys && w.repeat != 0:
		refused = {kind = .Duplicate_Key, at = w.repeat_min}
	case faulted:
		refused = {kind = .Walk, at = bad.at, inner = bad}
	case w.refuse && w.repeat != 0:
		refused = {kind = .Duplicate_Key, at = w.repeat}
	case w.clash != 0 && read.dups != .First && read.dups != .All:
		refused = {kind = .Duplicate_Key, at = w.clash}
	}
	if refused.kind != .None {
		w.reader.first = refused
	}
	return typed.read_end(&w.reader, regs, nil)
}

@(private)
walk_read_destroy :: proc(w: ^Walk_Read) {
	keys_destroy(&w.keys)
	delete(w.opens)
	delete(w.noted)
}

@(private)
walk_read_hook :: proc "contextless" (w: ^Walk_Read, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	t := t
	#partial switch t.role {
	case .Value:
		w.nodes += 1
		if t.kind == .String || t.kind == .Plain {
			t = value_typed(w, t)
		}
		w.tagged = false
		if t.kind == .Array || t.kind == .Object {
			keys_opened(w, t.kind == .Object)
		} else if t.kind == .End {
			keys_closed(w)
		}
	case .Key:
		if t.kind == .Array || t.kind == .Object {
			w.complex, w.found = t.lo, true
			return regs, .Stop
		}
		w.nodes += 1
		w.tagged = false
		key_noted(w, t)
	case .Tag:
		w.tag, w.tagged = t, true
		return regs, .Next
	case:
		return regs, .Next
	}
	if w.muted {
		return regs, .Next
	}
	switch w.skip {
	case 1:
		w.skip = 2 if t.kind == .Array || t.kind == .Object else 0
		w.skip_depth = 1
		return regs, .Next
	case 2:
		if t.kind == .Array || t.kind == .Object {
			w.skip_depth += 1
		} else if t.kind == .End {
			w.skip_depth -= 1
			if w.skip_depth == 0 {
				w.skip = 0
			}
		}
		return regs, .Next
	}
	if (t.kind == .Array || t.kind == .Object) && w.reader.sp + 2 > w.room {
		room, grown := typed.grow_frames(&w.reader, w.room, w.reader.sp + 2)
		if !grown {
			w.muted = true
			w.reader.first = {kind = .No_Memory}
			return regs, .Next
		}
		w.room = room
	}
	if t.kind == .Number && t.spelling & core.NUMBER_KIND_MASK == 0 {
		w.reader.mant = typed.fold_digits(w.src, t)
	}
	out, action := typed.on_token_spelled(&w.reader, regs, t)
	switch action {
	case .Stop:
		w.muted = true
	case .Skip:
		if t.kind == .Array || t.kind == .Object {
			w.skip, w.skip_depth = 2, 1
		} else if t.role == .Key {
			w.skip = 1
		}
	case .Next, .Keep:
	}
	return out, .Next
}

// Value scalar `t` as the reader takes it: a string under `!!str` or a tag of no core type, and under another core tag
// or none of the kind the core schema reads its text as.
@(private)
value_typed :: #force_inline proc "contextless" (w: ^Walk_Read, t: core.Token) -> core.Token {
	context = w.reader.ctx
	t := t
	if w.tagged {
		#partial switch doc_core_type(w.src, string(w.src[w.tag.lo:w.tag.lo + u64(w.tag.n)])) {
		case .None, .Str:
			t.kind = .String
			return t
		case .Int, .Float:
			return scalar_typed(w.src, t, .Number)
		}
		t.kind = .Plain
	}
	if t.kind != .Plain {
		return t
	}
	stack: [64]u8 = ---
	k: core.Kind
	switch classify(transmute([]u8)scalar_text(w.src, t, stack[:])) {
	case .Text:                              k = .String
	case .Null:                              k = .Null
	case .False:                             k = .False
	case .True:                              k = .True
	case .Decimal, .Hex, .Octal, .Inf, .Nan: k = .Number
	}
	return scalar_typed(w.src, t, k)
}

// Notes key `t` in its mapping, or judges it once a key of the text resolves to no string, and under `.Refuse`.
@(private)
key_noted :: #force_inline proc "contextless" (w: ^Walk_Read, t: core.Token) {
	if t.spelling & KEY_TAGS > u16(Key_Tag.Text) << KEY_TAG_SHIFT {
		w.typed_keys = true
	}
	if !w.judging && !w.typed_keys && len(w.noted) < cap(w.noted) {
		(^runtime.Raw_Dynamic_Array)(&w.noted).len += 1
		w.noted[len(w.noted) - 1] = t
		return
	}
	key_judged(w, t)
}

@(private)
key_judged :: #force_no_inline proc "contextless" (w: ^Walk_Read, t: core.Token) {
	context = runtime.default_context()
	if !w.judging && !w.typed_keys {
		append(&w.noted, t)
		return
	}
	if !w.judging {
		// Every key noted so far is text, so none clashes, and a read that does not refuse judges no repeat of them.
		w.judging = true
		for o, i in w.opens {
			keys_open(&w.keys, o.object)
			hi := len(w.noted) if i + 1 == len(w.opens) else int(w.opens[i + 1].first)
			for k in w.noted[o.first:hi] {
				key_enter(&w.keys, k, w.src)
			}
		}
	}
	judged := key_enter(&w.keys, t, w.src)
	at := core.node_start(t)
	if .Repeat in judged && w.refuse {
		if w.repeat == 0 {
			w.repeat = at
		}
		w.repeat_min = min(w.repeat_min, at)
	}
	if .Clash in judged && w.clash == 0 {
		w.clash = at
	}
}

@(private)
keys_opened :: #force_inline proc "contextless" (w: ^Walk_Read, object: bool) {
	if !w.judging && len(w.opens) < cap(w.opens) {
		(^runtime.Raw_Dynamic_Array)(&w.opens).len += 1
		w.opens[len(w.opens) - 1] = {u32(len(w.noted)), object}
		return
	}
	keys_opened_cold(w, object)
}

@(private)
keys_opened_cold :: #force_no_inline proc "contextless" (w: ^Walk_Read, object: bool) {
	context = runtime.default_context()
	if w.judging {
		keys_open(&w.keys, object)
	} else {
		append(&w.opens, Noted_Open{u32(len(w.noted)), object})
	}
}

@(private)
keys_closed :: #force_inline proc "contextless" (w: ^Walk_Read) {
	if w.judging {
		context = runtime.default_context()
		keys_close(&w.keys)
		return
	}
	o := w.opens[len(w.opens) - 1]
	(^runtime.Raw_Dynamic_Array)(&w.opens).len -= 1
	(^runtime.Raw_Dynamic_Array)(&w.noted).len = int(o.first)
}

// The check of a text: `text_read` with every refusal in `read.sink.entries`.
@(private)
text_check :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return typed.check_built_text(src, as, typed_build, target, T, plan, read, allocator)
}

// The build of a text whose scalars hold the kinds the reader takes.
@(private)
typed_build :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_as(src, as, refuse_duplicates, allocator)
	if err.kind == .None {
		type_scalars(&doc, core.ROOT, doc.nodes)
	}
	return doc, err
}

// The read of a node of a built document, a plan's `node_read`. The document's scalars are `Plain` until `resolve`
// types them, and the reader takes a token's kind as it stands, so the node's subtree is read from a copy whose value
// scalars hold their kinds.
@(private)
node_read :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return read_node(doc, node, T, target, plan, read, allocator, false)
}

// `node_read` with every refusal in `read.sink.entries`, a plan's `node_check`.
@(private)
node_check :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal {
	return read_node(doc, node, T, target, plan, read, allocator, true)
}

@(private)
read_node :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, $CHECK: bool) -> core.Typed_Refusal {
	size := core.subtree_size(doc, node)
	nodes, failed := slice.clone(doc.nodes[node:][:size])
	if failed != nil {
		return {kind = .No_Memory}
	}
	defer delete(nodes)
	type_scalars(doc, node, nodes)
	// The reader takes the nodes, the source and the format of a document and nothing a node's index names.
	subtree := doc^
	subtree.nodes = nodes
	when CHECK {
		return typed.check_nodes(&subtree, core.ROOT, T, target, plan, read, allocator)
	} else {
		return typed.read_nodes(&subtree, core.ROOT, T, target, plan, read, allocator)
	}
}

// Gives each plain value scalar of `nodes`, the nodes of `doc` from `first` on or a copy of them, the kind the core
// schema reads it as, since the reader takes a token's kind as it stands. A number takes the spelling of its form,
// which the reader reads it by. A quoted or block scalar a tag makes a number becomes the number its bytes spell between
// the quotes or past the header, and one whose text is not a run of its bytes, as an escaped digit, keeps its kind.
@(private)
type_scalars :: proc(doc: ^core.Document, first: core.Node_Index, nodes: []core.Node) {
	for &n, i in nodes {
		if n.kind == .Plain && n.role == .Value {
			n = scalar_typed(doc.src, n, spelling_resolve(doc, first + core.Node_Index(i)))
		}
	}
}

// Plain scalar `t` of `src` as a token of kind `k`, the kind the core schema reads it as, which `type_scalars` says.
@(private)
scalar_typed :: proc(src: []u8, t: core.Token, k: core.Kind) -> core.Token {
	t := t
	if k == .Number {
		span := src[t.lo:t.lo + u64(t.n)]
		if t.spelling & core.SPELLING_DECODE != 0 || style_of(t.spelling) != .Plain {
			stack: [64]u8 = ---
			text := scalar_text(src, t, stack[:])
			at := strings.index(string(span), text)
			if at < 0 {
				return t
			}
			span = span[at:][:len(text)]
			t.lo += u64(at)
			t.n = u32(len(span))
		}
		t.spelling = number_form(span)
	}
	t.kind = k
	return t
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

// The `spelling` of a number token whose text is `text`: a JSON number carries its digit counts, and any other form
// carries the kind a writer converts it by.
@(private)
number_form :: proc(text: []u8) -> u16 {
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'x': return 4
		case 'o': return 6
		}
	}
	#partial switch classify(text) {
	case .Inf: return 10
	case .Nan: return 12
	}
	int_digits, frac_digits, has_exp, ok := spell.number_shape_strict(text, 0, u64(len(text)))
	if !ok {
		return core.NUMBER_DECIMAL
	}
	return core.number_spelling(0, int_digits, frac_digits) | (core.NUMBER_EXP if has_exp else 0)
}

// Writes `value` as YAML into new bytes from `allocator`, as `write` says: a struct or map as a mapping, a list as a
// sequence, a byte string as `!!binary` and its base64, which `unmarshal` reads back into a
// `typed.Bytes`. A pretty layout writes block style with `write.indent` spaces a level, and a compact one flow style on
// one line. The text ends with a line end when it is pretty. The form with no plan builds and frees one for the call,
// and a plan made once with `plan_make` is the form for many writes.
marshal :: proc {marshal_once, cw.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Yaml_1_2, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	nothing: any
	v := typed.marshal_target(value, &nothing)
	plan, refusal := plan_make(v.id, spec, opts)
	return typed.marshal_planned(&plan, refusal, v.data, write, allocator)
}
