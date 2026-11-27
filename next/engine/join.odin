package engine

import "base:runtime"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/query"

// Multi-source loading and streaming join execution (`--with name=file`) over any format spec.

Aux_Source :: struct {
	name:         string,
	src:          []u8,
	spec:         Spec,
	opts:         tape.Options,
	framing:      Framing,
	index_by_key: string,
	group_dups:   bool,
}

Aux_Kind :: enum u8 {
	None,
	Single_Doc,
	Record_Array,
	Record_Members,
}

Aux_Member :: struct {
	key: string,
	doc: tape.Document,
}

Aux_Binding :: struct {
	name:        string,
	spec:        Spec,
	framing:     Framing,
	demand_mode: query.Demand_Mode,
	kind:        Aux_Kind,
	index_key:   string,
	group_dups:  bool,
	doc:         tape.Document,
	docs:        []tape.Document,
	members:     []Aux_Member,
	partial:     bool,
	records:     u64,
	allocator:   runtime.Allocator,
}

Aux_Set :: struct {
	bindings:  []Aux_Binding,
	allocator: runtime.Allocator,
}

Aux_Load_Result :: struct {
	err:      Exec_Error,
	read_err: tape.Error,
	failed:   string,
}

Join_Eval_Doc_Proc :: #type proc(ctx: rawptr, aux: ^Aux_Set, doc: ^tape.Document, meta: Record_Meta, emit: Emitter) -> Exec_Error
Join_Pred_Doc_Proc :: #type proc(ctx: rawptr, aux: ^Aux_Set, doc: ^tape.Document, meta: Record_Meta) -> (matched: bool, err: Exec_Error)

Join_Exec_Options :: struct {
	exec:     Exec_Options,
	route:    Route_Options,
	aux_eval: Join_Eval_Doc_Proc,
	aux_each: Join_Eval_Doc_Proc,
	aux_pred: Join_Pred_Doc_Proc,
	aux_ctx:  rawptr,
}

@(require_results)
load_aux_sources :: proc(
	plan: ^query.Plan,
	sources: []Aux_Source,
	allocator := context.allocator,
) -> (set: Aux_Set, res: Aux_Load_Result) {
	alloc := allocator if allocator.procedure != nil else context.allocator
	if len(sources) == 0 {
		return {allocator = alloc}, {}
	}
	bindings, berr := make([]Aux_Binding, len(sources), alloc)
	if berr != nil {
		return {}, {err = .No_Memory, read_err = berr}
	}
	set = {bindings = bindings, allocator = alloc}
	for s, idx in sources {
		b, lres := load_one_aux_source(plan, s, alloc)
		if lres.err != .None {
			destroy_aux_set(&set)
			lres.failed = s.name
			return {}, lres
		}
		set.bindings[idx] = b
	}
	return set, {}
}

destroy_aux_set :: proc(set: ^Aux_Set) {
	if set == nil {
		return
	}
	alloc := set.allocator if set.allocator.procedure != nil else context.allocator
	for &b in set.bindings {
		destroy_aux_binding(&b)
	}
	delete(set.bindings, alloc)
	set^ = {}
}

aux_binding_for :: proc "contextless" (set: ^Aux_Set, name: string) -> (^Aux_Binding, bool) {
	if set == nil || name == "" {
		return nil, false
	}
	for &b in set.bindings {
		if b.name == name {
			return &b, true
		}
	}
	return nil, false
}

@(require_results)
aux_binding_to_value :: proc(b: ^Aux_Binding, h: ^query.Heap) -> (val: query.Value, status: query.Status) {
	if b == nil || h == nil || b.kind == .None {
		return query.NULL, .Ok
	}
	raw_val := query.NULL
	switch b.kind {
	case .None:
		return query.NULL, .Ok
	case .Single_Doc:
		raw_val = query.make_array(h, 0) or_return if len(b.doc.nodes) == 0 else query.document_value(h, b.doc, owned = false) or_return
	case .Record_Array:
		raw_val = query.make_array(h, len(b.docs)) or_return
		for d in b.docs {
			if len(d.nodes) == 0 {
				continue
			}
			elem, es := query.document_value(h, d, owned = false)
			if es != .Ok || query.append_owned(h, &raw_val, elem) != .Ok {
				query.release(h, raw_val)
				return query.NULL, es if es != .Ok else .Error
			}
		}
	case .Record_Members:
		raw_val = query.make_object(h, len(b.members)) or_return
		for m in b.members {
			kstr, ks := query.text_value(h, m.key)
			if ks != .Ok {
				query.release(h, raw_val)
				return query.NULL, ks
			}
			mv := query.NULL
			if len(m.doc.nodes) > 0 {
				ms: query.Status
				mv, ms = query.document_value(h, m.doc, owned = false)
				if ms != .Ok {
					query.release(h, kstr)
					query.release(h, raw_val)
					return query.NULL, ms
				}
			}
			if ps := query.object_put(h, &raw_val, kstr, mv); ps != .Ok {
				query.release(h, raw_val)
				return query.NULL, ps
			}
		}
	}
	if b.index_key == "" {
		return raw_val, .Ok
	}
	defer query.release(h, raw_val)
	if query.type_of(raw_val) != .Array && query.type_of(raw_val) != .Object {
		return query.retain(raw_val), .Ok
	}
	return query.index_by_field(h, raw_val, b.index_key, b.group_dups)
}

@(private = "file")
hash_index_add_doc :: proc(idx: ^query.Hash_Index, h: ^query.Heap, d: tape.Document, field: string) -> query.Status {
	if len(d.nodes) == 0 {
		return .Ok
	}
	row := query.document_value(h, d, owned = false) or_return
	defer query.release(h, row)
	key, has_key, ks := extract_aux_row_key(h, row, field)
	defer query.release(h, key)
	if ks != .Ok {
		return ks
	}
	if has_key && key.kind != .Absent {
		return query.hash_index_add(idx, key, row)
	}
	return .Ok
}

@(require_results)
aux_binding_hash_index :: proc(b: ^Aux_Binding, h: ^query.Heap, key_field := "") -> (res: query.Hash_Index, status: query.Status) {
	if b == nil || h == nil {
		return {}, .Error
	}
	field := key_field if key_field != "" else b.index_key
	if b.kind == .None || (b.kind == .Single_Doc && len(b.doc.nodes) == 0) {
		empty_idx: query.Hash_Index
		query.hash_index_init(&empty_idx, h)
		_ = query.hash_index_seal(&empty_idx)
		return empty_idx, .Ok
	}
	if b.kind == .Single_Doc {
		coll := query.document_value(h, b.doc, owned = false) or_return
		defer query.release(h, coll)
		if field == "" {
			return query.hash_index_build(h, coll, nil)
		}
		return query.hash_index_build_field(h, coll, field)
	}
	idx: query.Hash_Index
	query.hash_index_init(&idx, h)
	ok := false
	defer if !ok {
		query.hash_index_destroy(&idx)
	}
	for d in b.docs {
		hash_index_add_doc(&idx, h, d, field) or_return
	}
	for m in b.members {
		hash_index_add_doc(&idx, h, m.doc, field) or_return
	}
	query.hash_index_seal(&idx) or_return
	ok = true
	return idx, .Ok
}

execute_with_sources :: proc(
	plan: ^query.Plan,
	src: []u8,
	spec: Spec,
	framing := Framing.Single,
	aux_sources: []Aux_Source = nil,
	opts := Join_Exec_Options{},
) -> (res: Exec_Result, load_res: Aux_Load_Result) {
	alloc := opts.exec.allocator if opts.exec.allocator.procedure != nil else context.allocator
	aux_set, lres := load_aux_sources(plan, aux_sources, alloc)
	if lres.err != .None {
		return {err = lres.err, read_err = lres.read_err}, lres
	}
	defer destroy_aux_set(&aux_set)

	r_opts := opts.route
	if r_opts.runner == nil {
		r_opts.runner = opts.exec.runner
	}
	r_opts.input_bytes = len(src)

	eff := opts.exec
	eff.allocator = alloc
	adapter: ^Join_Exec_Adapter

	if opts.aux_eval != nil || opts.aux_each != nil || opts.aux_pred != nil {
		aerr: runtime.Allocator_Error
		adapter, aerr = new(Join_Exec_Adapter, alloc)
		if aerr != nil {
			return {err = .No_Memory, read_err = aerr}, {err = .No_Memory, read_err = aerr}
		}
		has_workers := opts.exec.workers.init != nil
		eval_parent := opts.exec.eval_ctx if opts.exec.eval_ctx != nil else opts.aux_ctx
		each_parent := opts.exec.eval_each_ctx if opts.exec.eval_each_ctx != nil else opts.aux_ctx
		pred_parent := opts.exec.pred_ctx if opts.exec.pred_ctx != nil else opts.aux_ctx

		adapter^ = {
			user_workers       = opts.exec.workers,
			user_spine_collect = opts.exec.spine_collect,
			user_spine_reduce  = opts.exec.spine_reduce,
			user_spine_ctx     = eval_parent,
			alloc              = alloc,
			eval_slot          = {hdr = {aux = &aux_set, user_ctx = eval_parent, aux_eval = opts.aux_eval}, adapter = adapter, parent_ctx = eval_parent, use_workers = has_workers, raw_eval = opts.exec.eval},
			each_slot          = {hdr = {aux = &aux_set, user_ctx = each_parent, aux_each = opts.aux_each}, adapter = adapter, parent_ctx = each_parent, use_workers = has_workers, raw_eval = opts.exec.eval_each},
			pred_slot          = {hdr = {aux = &aux_set, user_ctx = pred_parent, aux_pred = opts.aux_pred}, adapter = adapter, parent_ctx = pred_parent, use_workers = has_workers && opts.exec.pred_ctx == nil},
		}
		thread_safe_user := opts.exec.eval_ctx_thread_safe || opts.aux_ctx == nil || has_workers
		r_opts.serial_eval_ctx = r_opts.serial_eval_ctx || !thread_safe_user || (opts.exec.pred_ctx != nil && !opts.exec.eval_ctx_thread_safe)

		if has_workers {
			eff.workers = {init = join_worker_init, fini = join_worker_fini}
		} else {
			eff.eval_ctx_thread_safe = thread_safe_user
		}
		if opts.aux_eval != nil || (has_workers && opts.exec.eval != nil) {
			eff.eval, eff.eval_ctx = join_eval_bridge, &adapter.eval_slot
		}
		if opts.aux_each != nil || (has_workers && opts.exec.eval_each != nil) {
			eff.eval_each, eff.eval_each_ctx = join_each_bridge, &adapter.each_slot
		}
		if opts.aux_pred != nil {
			eff.pred_eval, eff.pred_ctx = join_pred_bridge, &adapter.pred_slot
		}
		if opts.exec.spine_collect != nil && eff.eval_ctx == &adapter.eval_slot {
			eff.spine_collect = join_spine_collect_bridge
		}
		if opts.exec.spine_reduce != nil && eff.eval_ctx == &adapter.eval_slot {
			eff.spine_reduce = join_spine_reduce_bridge
		}
	}
	defer if adapter != nil {
		fini := adapter.user_workers.fini
		destroy_slot_serial_ctx(&adapter.eval_slot, fini)
		destroy_slot_serial_ctx(&adapter.each_slot, fini)
		destroy_slot_serial_ctx(&adapter.pred_slot, fini)
		free(adapter, alloc)
	}

	dec := decide(plan, spec, framing, r_opts)
	return execute(plan, &dec, src, eff), {}
}

// ---- Adapter hooks for `execute_with_sources`

@(private = "file")
Bridge_Header :: struct {
	aux:       ^Aux_Set,
	user_ctx:  rawptr,
	aux_eval:  Join_Eval_Doc_Proc,
	aux_each:  Join_Eval_Doc_Proc,
	aux_pred:  Join_Pred_Doc_Proc,
	is_worker: bool,
}

@(private = "file")
Bridge_Slot :: struct {
	using hdr:    Bridge_Header,
	adapter:      ^Join_Exec_Adapter,
	parent_ctx:   rawptr,
	raw_eval:     Eval_Doc_Proc,
	serial_ctx:   rawptr,
	serial_ready: bool,
	use_workers:  bool,
}

@(private = "file")
Join_Exec_Adapter :: struct {
	eval_slot:          Bridge_Slot,
	each_slot:          Bridge_Slot,
	pred_slot:          Bridge_Slot,
	user_workers:       Worker_Hooks,
	user_spine_collect: Spine_Collect_Proc,
	user_spine_reduce:  Spine_Reduce_Proc,
	user_spine_ctx:     rawptr,
	alloc:              runtime.Allocator,
}

@(private = "file")
Join_Worker_Ctx :: struct {
	using hdr: Bridge_Header,
	slot:      ^Bridge_Slot,
	alloc:     runtime.Allocator,
}

@(private = "file")
slot_effective_user_ctx :: proc(h: ^Bridge_Header) -> rawptr {
	if h.is_worker {
		return h.user_ctx
	}
	slot := (^Bridge_Slot)(h)
	if !slot.use_workers || slot.adapter == nil || slot.adapter.user_workers.init == nil {
		return slot.parent_ctx
	}
	if !slot.serial_ready {
		slot.serial_ctx = slot.adapter.user_workers.init(slot.parent_ctx, 0, slot.adapter.alloc)
		slot.serial_ready = true
	}
	return slot.serial_ctx
}

@(private = "file")
destroy_slot_serial_ctx :: proc(slot: ^Bridge_Slot, fini: proc(parent_ctx: rawptr, worker_idx: int, worker_ctx: rawptr)) {
	if slot.serial_ready {
		if fini != nil {
			fini(slot.parent_ctx, 0, slot.serial_ctx)
		}
		slot.serial_ctx, slot.serial_ready = nil, false
	}
}

@(private = "file")
join_worker_init :: proc(parent_ctx: rawptr, worker_idx: int, alloc: runtime.Allocator) -> rawptr {
	slot := (^Bridge_Slot)(parent_ctx)
	ws, err := new(Join_Worker_Ctx, alloc)
	if err != nil {
		return nil
	}
	ws^ = {hdr = slot.hdr, slot = slot, alloc = alloc}
	ws.hdr.is_worker = true
	ws.hdr.user_ctx = slot.adapter.user_workers.init(slot.parent_ctx, worker_idx, alloc)
	return ws
}

@(private = "file")
join_worker_fini :: proc(_: rawptr, worker_idx: int, worker_ctx: rawptr) {
	ws := (^Join_Worker_Ctx)(worker_ctx)
	if ws == nil {
		return
	}
	if fini := ws.slot.adapter.user_workers.fini; fini != nil {
		fini(ws.slot.parent_ctx, worker_idx, ws.hdr.user_ctx)
	}
	free(ws, ws.alloc)
}

@(private = "file")
join_bridge_run :: proc(ctx: rawptr, doc: ^tape.Document, meta: Record_Meta, emit: Emitter, use_each: bool) -> Exec_Error {
	if ctx == nil {
		return .Unsupported
	}
	h := (^Bridge_Header)(ctx)
	uctx := slot_effective_user_ctx(h)
	if aux_fn := h.aux_each if use_each else h.aux_eval; aux_fn != nil {
		return aux_fn(uctx, h.aux, doc, meta, emit)
	}
	raw_eval := (^Bridge_Slot)(ctx).raw_eval if !h.is_worker else (^Join_Worker_Ctx)(ctx).slot.raw_eval
	return raw_eval(uctx, doc, meta, emit) if raw_eval != nil else .Unsupported
}

@(private = "file")
join_eval_bridge :: proc(ctx: rawptr, doc: ^tape.Document, meta: Record_Meta, emit: Emitter) -> Exec_Error {
	return join_bridge_run(ctx, doc, meta, emit, false)
}

@(private = "file")
join_each_bridge :: proc(ctx: rawptr, doc: ^tape.Document, meta: Record_Meta, emit: Emitter) -> Exec_Error {
	return join_bridge_run(ctx, doc, meta, emit, true)
}

@(private = "file")
join_pred_bridge :: proc(ctx: rawptr, doc: ^tape.Document, meta: Record_Meta) -> (matched: bool, err: Exec_Error) {
	if ctx == nil {
		return false, .Unsupported
	}
	h := (^Bridge_Header)(ctx)
	if h.aux_pred == nil {
		return false, .Unsupported
	}
	return h.aux_pred(slot_effective_user_ctx(h), h.aux, doc, meta)
}

@(private = "file")
join_spine_collect_bridge :: proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: Emitter) -> Exec_Error {
	if ctx == nil {
		return .Unsupported
	}
	slot := (^Bridge_Slot)(ctx)
	if slot.adapter == nil || slot.adapter.user_spine_collect == nil {
		return .Unsupported
	}
	return slot.adapter.user_spine_collect(slot.adapter.user_spine_ctx, doc, item_outputs, emit)
}

@(private = "file")
join_spine_reduce_bridge :: proc(ctx: rawptr, doc: ^tape.Document, item_outputs: [][]u8, emit: Emitter) -> Exec_Error {
	if ctx == nil {
		return .Unsupported
	}
	slot := (^Bridge_Slot)(ctx)
	if slot.adapter == nil || slot.adapter.user_spine_reduce == nil {
		return .Unsupported
	}
	return slot.adapter.user_spine_reduce(slot.adapter.user_spine_ctx, doc, item_outputs, emit)
}

// ---- Private loading helpers

@(private = "file")
destroy_aux_binding :: proc(b: ^Aux_Binding) {
	if b == nil {
		return
	}
	alloc := b.allocator if b.allocator.procedure != nil else context.allocator
	delete(b.name, alloc)
	delete(b.index_key, alloc)
	switch b.kind {
	case .None:
	case .Single_Doc:
		tape.destroy(&b.doc)
	case .Record_Array:
		for &d in b.docs {
			tape.destroy(&d)
		}
		delete(b.docs, alloc)
	case .Record_Members:
		for &m in b.members {
			delete(m.key, alloc)
			tape.destroy(&m.doc)
		}
		delete(b.members, alloc)
	}
	b^ = {}
}

@(private = "file")
extract_aux_row_key :: proc(h: ^query.Heap, row: query.Value, field: string) -> (key: query.Value, ok: bool, status: query.Status) {
	if field == "" {
		return query.retain(row), true, .Ok
	}
	if query.type_of(row) != .Object {
		return query.ABSENT, false, .Ok
	}
	v, s := query.member(h, row, field)
	if s != .Ok || v.kind == .Absent {
		return query.ABSENT, false, s
	}
	return v, true, .Ok
}

@(private = "file")
load_one_aux_source :: proc(plan: ^query.Plan, s: Aux_Source, alloc: runtime.Allocator) -> (Aux_Binding, Aux_Load_Result) {
	entry, spec_ok := entry_of_spec(s.spec)
	if !spec_ok {
		return {}, {err = .Unsupported, read_err = tape.Bad_Option{"spec"}}
	}
	name_copy, nerr := strings.clone(s.name, alloc)
	if nerr != nil {
		return {}, {err = .No_Memory, read_err = nerr}
	}
	key_copy: string
	if s.index_by_key != "" {
		kerr: runtime.Allocator_Error
		key_copy, kerr = strings.clone(s.index_by_key, alloc)
		if kerr != nil {
			delete(name_copy, alloc)
			return {}, {err = .No_Memory, read_err = kerr}
		}
	}
	b := Aux_Binding{name = name_copy, spec = entry.spec, framing = s.framing, index_key = key_copy, group_dups = s.group_dups, allocator = alloc}
	cleanup := true
	defer if cleanup {
		destroy_aux_binding(&b)
	}

	aux_dem, has_dem := query.aux_demand_for(plan, s.name)
	eff_mode := aux_dem.mode if (plan != nil && has_dem) else query.Demand_Mode.Whole
	b.demand_mode = eff_mode
	if plan != nil && has_dem && eff_mode == .None {
		b.kind = .None
		cleanup = false
		return b, {}
	}

	lres := load_aux_single_doc(&b, entry, s, aux_dem if has_dem else nil, alloc) if (s.framing == .Single || entry.family == .Dsv) else load_aux_framed(&b, entry, s, aux_dem if has_dem else nil, alloc)
	if lres.err != .None {
		return {}, lres
	}
	cleanup = false
	return b, {}
}

@(private = "file")
load_aux_single_doc :: proc(b: ^Aux_Binding, entry: Format_Entry, s: Aux_Source, aux_dem: ^query.Source_Demand, alloc: runtime.Allocator) -> Aux_Load_Result {
	if aux_dem != nil && aux_dem.mode == .Partial && entry.supports_scan && !dups_needs_build(entry, s.opts.dups) {
		ro := s.opts
		ro.runner = nil
		dem, dem_owned, derr := prepare_single_aux_demand(aux_dem, s.index_by_key, alloc)
		if derr != nil {
			return {err = .No_Memory, read_err = derr}
		}
		defer if dem_owned {
			tape.destroy_demand(&dem)
		}
		doc, ser := scan(s.src, &dem, entry.spec, {}, ro, alloc)
		if ser != nil {
			return {err = .No_Memory if is_alloc_err(ser) else .Read_Error, read_err = ser}
		}
		b.kind, b.doc, b.partial, b.records = .Single_Doc, doc, true, 1
		return {}
	}
	doc, ber := build(s.src, entry.spec, s.opts, alloc)
	if ber != nil {
		return {err = .No_Memory if is_alloc_err(ber) else .Read_Error, read_err = ber}
	}
	b.kind, b.doc, b.partial, b.records = .Single_Doc, doc, false, 1
	return {}
}

@(private = "file")
prepare_single_aux_demand :: proc(aux_dem: ^query.Source_Demand, index_by_key: string, alloc: runtime.Allocator) -> (dem: tape.Demand, owned: bool, err: runtime.Allocator_Error) {
	if index_by_key == "" {
		return aux_dem.demand, false, nil
	}
	prefix_end, matched_pi := 0, -1
	outer: for p, pi in aux_dem.paths {
		for step, si in p.steps {
			if _, is_all := step.(tape.All); is_all {
				prefix_end, matched_pi = si, pi
				break outer
			}
		}
	}
	prefix := aux_dem.paths[matched_pi].steps[:prefix_end] if matched_pi >= 0 else nil
	if matched_pi >= 0 && prefix_end > 0 {
		for p in aux_dem.paths {
			for step in p.steps {
				if _, is_all := step.(tape.All); is_all {
					if !query.steps_prefix(prefix, p.steps) {
						prefix = nil
					}
					break
				}
			}
			if prefix == nil {
				break
			}
		}
	}

	key_steps := make([]tape.Step, len(prefix) + 2, alloc) or_return
	defer delete(key_steps, alloc)
	copy(key_steps[:len(prefix)], prefix)
	key_steps[len(prefix)] = tape.All{}
	key_steps[len(prefix) + 1] = tape.Name(index_by_key)

	for p in aux_dem.paths {
		if query.steps_equal(p.steps, key_steps) && p.grain == .Whole && p.limit == 0 {
			return aux_dem.demand, false, nil
		}
	}

	n := len(aux_dem.paths)
	raw_steps := make([][]tape.Step, n + 1, alloc) or_return
	defer delete(raw_steps, alloc)
	grains := make([]tape.Grain, n + 1, alloc) or_return
	defer delete(grains, alloc)
	limits := make([]int, n + 1, alloc) or_return
	defer delete(limits, alloc)
	for p, i in aux_dem.paths {
		raw_steps[i], grains[i], limits[i] = p.steps, p.grain, p.limit
	}
	raw_steps[n], grains[n], limits[n] = key_steps, .Whole, 0
	d := tape.demand_of(raw_steps, grains, limits, aux_dem.facts, alloc) or_return
	return d, true, nil
}

@(private = "file")
push_aux_record :: proc(
	docs_dyn: ^[dynamic]tape.Document,
	members_dyn: ^[dynamic]Aux_Member,
	is_members: bool,
	fmt_ptr: ^tape.Format,
	src: []u8,
	r_info: tape.Record,
	doc: tape.Document,
	alloc: runtime.Allocator,
) -> Aux_Load_Result {
	d := doc
	if is_members {
		key_str, kok := tape.node_text_read(fmt_ptr, src, r_info.key, alloc)
		if !kok {
			tape.destroy(&d)
			return {err = .No_Memory}
		}
		if _, aerr := append(members_dyn, Aux_Member{key = key_str, doc = d}); aerr != nil {
			delete(key_str, alloc)
			tape.destroy(&d)
			return {err = .No_Memory, read_err = aerr}
		}
	} else if _, aerr := append(docs_dyn, d); aerr != nil {
		tape.destroy(&d)
		return {err = .No_Memory, read_err = aerr}
	}
	return {}
}

@(private = "file")
load_aux_framed :: proc(b: ^Aux_Binding, entry: Format_Entry, s: Aux_Source, aux_dem: ^query.Source_Demand, alloc: runtime.Allocator) -> Aux_Load_Result {
	tf, framed := to_tape_framing(s.framing)
	if !framed {
		return {err = .Unsupported, read_err = tape.Bad_Option{"framing"}}
	}
	ro := s.opts
	ro.runner = nil
	use_scan, rec_dem, dem_owned, dem_err := prepare_framed_aux_demand(aux_dem, s.framing, s.index_by_key, entry, ro.dups, alloc)
	if dem_err != nil {
		return {err = .No_Memory, read_err = dem_err}
	}
	defer if dem_owned {
		tape.destroy_demand(&rec_dem)
	}

	frame_ro := ro
	if !use_scan {
		frame_ro.dups = .Default
	}
	recs, oerr := records_open(s.src, entry.spec, tf, frame_ro, nil, alloc)
	if oerr != nil {
		return {err = .No_Memory if is_alloc_err(oerr) else .Read_Error, read_err = oerr}
	}
	if recs == nil {
		return {err = .Unsupported}
	}
	defer tape.destroy_records(recs)
	if recs.err != nil {
		return {err = .No_Memory if is_alloc_err(recs.err) else .Read_Error, read_err = recs.err}
	}

	is_members := s.framing == .Members
	docs_dyn: [dynamic]tape.Document
	members_dyn: [dynamic]Aux_Member
	docs_dyn.allocator, members_dyn.allocator = alloc, alloc
	clean_partial := true
	defer if clean_partial {
		for &d in docs_dyn { tape.destroy(&d) }
		delete(docs_dyn)
		for &m in members_dyn { delete(m.key, alloc); tape.destroy(&m.doc) }
		delete(members_dyn)
	}

	out_recs: [RECORD_BATCH_SIZE]tape.Record
	batch_docs: [RECORD_BATCH_SIZE]tape.Document
	answers: [RECORD_BATCH_SIZE]tape.Span_Answer
	for {
		n := tape.records_scan(recs, &rec_dem, out_recs[:], batch_docs[:], {}, alloc) if use_scan else tape.records_find(recs, nil, out_recs[:], answers[:], {}, alloc)
		if n == 0 {
			break
		}
		for i in 0 ..< n {
			r_info := out_recs[i]
			if r_info.err != nil {
				return {err = .No_Memory if is_alloc_err(r_info.err) else .Read_Error, read_err = r_info.err}
			}
			rec_doc: tape.Document
			if use_scan {
				cerr: runtime.Allocator_Error
				rec_doc, cerr = tape.clone_document(&batch_docs[i], alloc)
				if cerr != nil {
					return {err = .No_Memory, read_err = cerr}
				}
			} else {
				berr: tape.Error
				rec_doc, berr = build(record_slice(s.src, r_info), entry.spec, ro, alloc)
				if berr != nil {
					return {err = .No_Memory if is_alloc_err(berr) else .Read_Error, read_err = berr}
				}
			}
			if pres := push_aux_record(&docs_dyn, &members_dyn, is_members, entry.format, s.src, r_info, rec_doc, alloc); pres.err != .None {
				return pres
			}
			b.records += 1
		}
	}
	if recs.err != nil {
		return {err = .No_Memory if is_alloc_err(recs.err) else .Read_Error, read_err = recs.err}
	}

	b.partial = use_scan
	if is_members {
		b.kind, b.members = .Record_Members, members_dyn[:]
	} else {
		b.kind, b.docs = .Record_Array, docs_dyn[:]
	}
	clean_partial = false
	return {}
}

@(private = "file")
prepare_framed_aux_demand :: proc(
	aux_dem: ^query.Source_Demand,
	framing: Framing,
	index_by_key: string,
	entry: Format_Entry,
	dups: tape.Duplicates,
	alloc: runtime.Allocator,
) -> (use_scan: bool, rec_dem: tape.Demand, dem_owned: bool, err: runtime.Allocator_Error) {
	if !entry.supports_scan || dups_needs_build(entry, dups) || aux_dem == nil || aux_dem.mode != .Partial {
		return false, {}, false, nil
	}
	steps_list := make([dynamic][]tape.Step, 0, len(aux_dem.paths) + 1, alloc) or_return
	defer delete(steps_list)
	grains := make([dynamic]tape.Grain, 0, len(aux_dem.paths) + 1, alloc) or_return
	defer delete(grains)

	is_members := framing == .Members
	key_step := [1]tape.Step{tape.Name(index_by_key)}

	for p in aux_dem.paths {
		if len(p.steps) == 0 {
			if p.grain == .Whole {
				return false, {}, false, nil
			}
			append(&steps_list, []tape.Step{}) or_return
			append(&grains, tape.Grain.Exists) or_return
			continue
		}
		head, rest := p.steps[0], p.steps[1:]
		unwrap: bool
		#partial switch _ in head {
		case tape.All:                  unwrap = true
		case tape.Name:                 unwrap = is_members
		case tape.Index, tape.Slice:    unwrap = !is_members
		case tape.Descend:              return false, {}, false, nil
		}
		if !unwrap {
			append(&steps_list, []tape.Step{}) or_return
			append(&grains, tape.Grain.Exists) or_return
			continue
		}
		if len(rest) == 0 && p.grain == .Whole {
			return false, {}, false, nil
		}
		append(&steps_list, rest) or_return
		append(&grains, p.grain) or_return
	}
	if index_by_key != "" {
		append(&steps_list, key_step[:]) or_return
		append(&grains, tape.Grain.Whole) or_return
	}
	if len(steps_list) == 0 {
		append(&steps_list, []tape.Step{}) or_return
		append(&grains, tape.Grain.Exists) or_return
	}
	if len(steps_list) > query.MAX_DEMAND_PATHS {
		return false, {}, false, nil
	}
	d := tape.demand_of(steps_list[:], grains[:], nil, aux_dem.facts, alloc) or_return
	if len(d.nodes) > query.MAX_DEMAND_NODES {
		tape.destroy_demand(&d)
		return false, {}, false, nil
	}
	return true, d, true, nil
}
