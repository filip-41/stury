package typed

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Parallel typed unmarshal for large root or nested spine lists (`.Slice` / `.Dynamic`).
//
// Allocator policy (ruling 8):
// - `.Free_All` without `.Free` (arenas, temp allocator): per-worker doubling bump blocks allocated from `caller`
//   under the read's lock; frees on repeats are no-ops.
// - `runtime.heap_allocator_proc` with `Budget.memory == 0`: workers call `caller` directly (exact 1 alloc per
//   string/list as serial).
// - Any other allocator (tracking, stack, scratch, unknown, or heap with `Budget.memory != 0`): falls back to serial
//   with zero data races.
//
// Read scratch (frames, `before`, `held`, `zero`, `seen` wide words, `first_met` sets, `Refusing_Reader` tables, and
// worker temporary element buffers) never lives in worker result blocks. Any chunk fault, type refusal, or refused
// allocation discards worker outputs, restores `target`, and falls back to the serial read so results always equal
// serial.

// Minimum bytes in the list tail to engage parallel typed unmarshal. Respects `BUILD_PARALLEL_FROM`.
PARALLEL_FROM :: #config(BUILD_PARALLEL_FROM, 1 << 19)

// Maximum parts per parallel typed read (kept on the stack).
MAX_PARALLEL_PARTS :: 128

// Minimum and maximum sizes for per-worker bump blocks in `.Blocks` mode.
@(private)
BLOCK_MIN :: 4 << 10
@(private)
BLOCK_INIT :: 64 << 10
@(private)
BLOCK_MAX :: 4 << 20

// Classification of the caller's allocator per ruling 8.
Alloc_Class :: enum u8 {
	Serial, // unknown, tracking, stack, scratch, or heap with Budget.memory != 0
	Blocks, // `.Free_All` without `.Free` (arenas, temp allocator) -> per-worker doubling bump blocks under lock
	Direct, // `runtime.heap_allocator_proc` with `Budget.memory == 0` -> workers call `caller` directly
}

// Classifies `caller` under `opts` via `.Query_Features` per ruling 8:
// - `.Free_All` without `.Free` (growing arenas, temp allocator) -> `.Blocks` (per-worker doubling bump blocks under
//   lock; each block starts at `clamp(part_bytes/4, 4 KiB, 64 KiB)` to avoid excess slack on small chunks). Callers
//   passing a tightly bounded fixed `mem.Arena` should either set `opts.budget.memory` or omit `opts.runner`.
// - `runtime.heap_allocator_proc` with `opts.budget.memory == 0` -> `.Direct`.
// - All other allocators -> `.Serial`.
parallel_alloc_class :: proc(caller: runtime.Allocator, opts: tape.Options) -> Alloc_Class {
	if caller.procedure == nil {
		return .Serial
	}
	features: runtime.Allocator_Mode_Set
	_, err := caller.procedure(caller.data, .Query_Features, 0, 0, &features, 0)
	if err == nil && .Free_All in features && .Free not_in features {
		// Under a tight memory budget smaller than two init blocks, stay serial so speculative worker blocks cannot
		// prematurely exhaust the budget before a serial retry.
		if opts.budget.memory != 0 && opts.budget.memory < BLOCK_INIT * 2 {
			return .Serial
		}
		return .Blocks
	}
	if caller.procedure == runtime.heap_allocator_proc && opts.budget.memory == 0 {
		return .Direct
	}
	return .Serial
}

// Target list discovered by the serial prefix probe (or root check for flat formats like DSV).
Parallel_List :: struct {
	owner: ^Record, // `.Slice` or `.Dynamic` record
	dest:  uintptr, // address of the target slice or dynamic array
	depth: int,     // container depth of the open list (1 for root array, >1 for nested spine)
	open:  u64,     // byte offset right after the array opener
}

// One chunk of elements of a parallel list.
Parallel_Part :: struct {
	from, to: int,
}

// Wrapper hook for the serial prefix walk that stops immediately upon opening a `.Slice` or `.Dynamic` target with a
// large remaining tail. `inner` sits at offset 0 so all fields (`expected`, `protocol`, `reader`) are inherited.
Probe_Reader :: struct($H: typeid) {
	using inner: H,
	found:       Parallel_List,
	min_tail:    u64,
	max_depth:   int,
}

#assert(offset_of(Probe_Reader(Text_Reader), inner) == 0)
#assert(offset_of(Probe_Reader(Refusing_Reader), inner) == 0)

// Prefix probe hook wrapping `text_hook`.
probe_text_hook :: #force_inline proc "contextless" (h: ^Probe_Reader(Text_Reader), s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	r, a := text_hook(&h.inner, s, t, number)
	if t.kind == .Array && t.role == .Value && a == .Next {
		if probe_hit(h, t) {
			return r, .Stop
		}
	}
	return r, a
}

// Prefix probe hook wrapping `refusing_hook`.
probe_refusing_hook :: #force_inline proc "contextless" (h: ^Probe_Reader(Refusing_Reader), s: hook.Regs, t: tape.Token, $number: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number) -> (hook.Regs, hook.Action) {
	r, a := refusing_hook(&h.inner, s, t, number)
	if t.kind == .Array && t.role == .Value && a == .Next && !h.done && h.passing == 0 && !h.value {
		if probe_hit(h, t) {
			return r, .Stop
		}
	}
	return r, a
}

@(private)
probe_hit :: #force_inline proc "contextless" (h: ^Probe_Reader($H), t: tape.Token) -> bool {
	if .Dead in h.flags || h.sp < 2 || h.sp > h.max_depth {
		return false
	}
	after := t.lo + u64(t.n)
	if after >= h.len || h.len - after < h.min_tail {
		return false
	}
	f := &h.frames[h.sp - 1]
	owner := frame_owner(f)
	if owner.kind != .Slice && owner.kind != .Dynamic {
		return false
	}
	h.found = {owner = owner, dest = list_dest(f, owner), depth = h.sp - 1, open = after}
	return true
}

// Shared pool backing per-worker bump blocks in `.Blocks` mode, and shared lock for `opts.scratch` / `Budget.memory`.
@(private)
Block_Pool :: struct {
	lock:    sync.Mutex,
	backing: runtime.Allocator,
	limit:   u64,
	held:    u64,
	refused: bool,
}

@(private)
pool_alloc_locked :: proc(pool: ^Block_Pool, size, align: int, zero: bool) -> ([]u8, runtime.Allocator_Error) {
	sync.mutex_guard(&pool.lock)
	if pool.limit != 0 && u64(size) > pool.limit - min(pool.held, pool.limit) {
		pool.refused = true
		return nil, .Out_Of_Memory
	}
	data: []u8
	err: runtime.Allocator_Error
	if zero {
		data, err = runtime.mem_alloc(size, align, pool.backing)
	} else {
		data, err = runtime.mem_alloc_non_zeroed(size, align, pool.backing)
	}
	if err != nil {
		return nil, err
	}
	pool.held += u64(size)
	return data, nil
}

// Per-worker bump-block allocator for `.Blocks` mode (ruling 8). Frees are no-ops; refills double from `next` under lock.
@(private)
Worker_Block :: struct {
	pool: ^Block_Pool,
	buf:  []u8,
	used: int,
	last: int,
	next: int,
}

@(private)
worker_block_allocator :: proc "contextless" (b: ^Worker_Block) -> runtime.Allocator {
	return {worker_block_proc, b}
}

@(private)
worker_block_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	b := (^Worker_Block)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size <= 0 {
			return nil, nil
		}
		out, err := worker_block_take(b, size, alignment)
		if err == nil && mode == .Alloc {
			runtime.mem_zero(raw_data(out), size)
		}
		return out, err
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return worker_block_proc(data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		}
		if size <= 0 {
			return nil, nil
		}
		old_p := uintptr(old_memory)
		buf_p := uintptr(raw_data(b.buf))
		if b.buf != nil && old_p >= buf_p && old_p < buf_p + uintptr(len(b.buf)) {
			at := int(old_p - buf_p)
			if at == b.last && at + size <= len(b.buf) {
				b.used = at + size
				if mode == .Resize && size > old_size {
					runtime.mem_zero(&b.buf[at + old_size], size - old_size)
				}
				return b.buf[at:][:size], nil
			}
		}
		if size <= old_size {
			return ([^]u8)(old_memory)[:size], nil
		}
		out, err := worker_block_take(b, size, alignment)
		if err != nil {
			return nil, err
		}
		if old_size > 0 {
			runtime.mem_copy_non_overlapping(raw_data(out), old_memory, old_size)
		}
		if mode == .Resize {
			runtime.mem_zero(&out[old_size], size - old_size)
		}
		return out, nil
	case .Free, .Free_All:
		return nil, nil
	case .Query_Features:
		if set := (^runtime.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Free_All, .Query_Features}
		}
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}

@(private)
worker_block_take :: #force_inline proc(b: ^Worker_Block, size, alignment: int) -> ([]u8, runtime.Allocator_Error) {
	align := max(alignment, 1)
	if b.buf != nil {
		base := uintptr(raw_data(b.buf))
		at := int((base + uintptr(b.used) + uintptr(align - 1)) &~ uintptr(align - 1) - base)
		if at + size <= len(b.buf) {
			b.last, b.used = at, at + size
			return b.buf[at:][:size], nil
		}
	}
	return worker_block_grow(b, size, align)
}

@(private, cold)
worker_block_grow :: proc(b: ^Worker_Block, size, align: int) -> ([]u8, runtime.Allocator_Error) {
	grow := max(b.next, size + align)
	data, err := pool_alloc_locked(b.pool, grow, max(align, 64), false)
	if err != nil {
		return nil, err
	}
	b.next = min(max(b.next * 2, BLOCK_INIT), BLOCK_MAX)
	b.buf, b.last, b.used = data, 0, size
	return b.buf[:size], nil
}

// Mutex-guarded scratch allocator (also counting against `pool.limit` when `pool != nil && pool.limit != 0`).
parallel_scratch_backing :: #force_inline proc "contextless" (opts: tape.Options, caller: runtime.Allocator) -> runtime.Allocator {
	if opts.scratch.procedure != nil {
		return opts.scratch
	}
	when ODIN_DEFAULT_TO_NIL_ALLOCATOR || ODIN_DEFAULT_TO_PANIC_ALLOCATOR {
		return caller
	} else {
		return {runtime.default_allocator_proc, nil}
	}
}

@(private)
Locked_Scratch :: struct {
	lock:    sync.Mutex,
	backing: runtime.Allocator,
	pool:    ^Block_Pool,
}

@(private)
locked_scratch_allocator :: proc "contextless" (s: ^Locked_Scratch) -> runtime.Allocator {
	return {locked_scratch_proc, s}
}

@(private)
locked_scratch_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	s := (^Locked_Scratch)(data)
	if s.pool != nil {
		sync.mutex_guard(&s.pool.lock)
		if s.pool.limit != 0 {
			grows := 0
			#partial switch mode {
			case .Alloc, .Alloc_Non_Zeroed:
				grows = size
			case .Resize, .Resize_Non_Zeroed:
				grows = size - old_size
			}
			if grows > 0 && u64(grows) > s.pool.limit - min(s.pool.held, s.pool.limit) {
				s.pool.refused = true
				return nil, .Out_Of_Memory
			}
		}
		block, err := s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
		if err != nil {
			return block, err
		}
		if s.pool.limit != 0 {
			#partial switch mode {
			case .Alloc, .Alloc_Non_Zeroed:
				s.pool.held += u64(size)
			case .Resize, .Resize_Non_Zeroed:
				s.pool.held = s.pool.held - min(s.pool.held, u64(old_size)) + u64(size)
			case .Free:
				s.pool.held -= min(s.pool.held, u64(old_size))
			}
		}
		return block, nil
	}
	sync.mutex_guard(&s.lock)
	return s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Wrapper record used as frame 1's sentinel in parallel workers so `list_dest` writes directly to `f.target`.
@(private, rodata)
WORKER_LIST_WRAPPER := [2]Record{{word = NO_KEY, kind = .Position}, {word = NO_KEY, kind = .End}}

// Per-worker output for one chunk of elements.
@(private)
Worker_Out :: struct {
	list:   runtime.Raw_Dynamic_Array,
	offset: int,
	err:    tape.Error,
	astray: bool,
}

// Outcome of walking one worker's part of a parallel list.
Part_Result :: struct {
	err:    tape.Error,
	astray: bool,
}

// Shared precondition checks and plan resolution for `read_parallel_list` and `read_parallel_spine`.
@(private)
parallel_prepare :: proc(
	target: rawptr,
	T: typeid,
	format: ^tape.Format,
	tag: string,
	opts: tape.Options,
	uopts: Unmarshal_Options,
	caller: runtime.Allocator,
	made_buf: ^Plan,
) -> (plan: ^Plan, dups: tape.Duplicates, class: Alloc_Class, made, ok: bool) {
	if target == nil || opts.runner == nil || opts.runner.threads <= 0 || opts.pieces != nil || opts.budget.steps != 0 || tape.options_refused(format, opts) != nil {
		return
	}
	dups = format.dups if opts.dups == .Default else opts.dups
	if dups == .All || dups == .Group {
		return
	}
	class = parallel_alloc_class(caller, opts)
	if class == .Serial {
		return
	}
	plan = uopts.plan
	if plan == nil {
		if perr := make_temp_plan(T, tag, caller, made_buf); perr != nil {
			return
		}
		plan = made_buf
		made = true
	} else if plan.type != T || !(len(plan.tag) == len(tag) && (raw_data(plan.tag) == raw_data(tag) || plan.tag == tag)) {
		return
	}
	if uopts.path != nil {
		clear(uopts.path)
	}
	ok = true
	return
}

// Checks preconditions for `read_parallel_list`, verifying that `T` is a slice or dynamic array.
parallel_list_ready :: proc(
	target: rawptr,
	T: typeid,
	format: ^tape.Format,
	tag: string,
	opts: tape.Options,
	uopts: Unmarshal_Options,
	caller: runtime.Allocator,
) -> bool {
	if target == nil || opts.runner == nil || opts.runner.threads <= 0 || opts.pieces != nil || opts.budget.steps != 0 || tape.options_refused(format, opts) != nil {
		return false
	}
	dups := format.dups if opts.dups == .Default else opts.dups
	if dups == .All || dups == .Group || parallel_alloc_class(caller, opts) == .Serial {
		return false
	}
	if uopts.plan != nil {
		if uopts.plan.type != T || !(len(uopts.plan.tag) == len(tag) && (raw_data(uopts.plan.tag) == raw_data(tag) || uopts.plan.tag == tag)) {
			return false
		}
		root_rec := (^Record)(uintptr(uopts.plan.root) - size_of(Record))
		return root_rec.kind == .Slice || root_rec.kind == .Dynamic
	}
	#partial switch _ in runtime.type_info_base(type_info_of(T)).variant {
	case ^runtime.Type_Info_Slice, ^runtime.Type_Info_Dynamic_Array:
		return true
	}
	return false
}

// Direct parallel typed read for a root list (such as DSV rows). Returns `done = false` to fall back to serial.
@(require_results)
read_parallel_list :: proc(
	src: []u8,
	target: rawptr,
	T: typeid,
	format: ^tape.Format,
	rules: ^tape.Rules,
	tag: string,
	opts: tape.Options,
	uopts: Unmarshal_Options,
	caller: runtime.Allocator,
	parts: []Parallel_Part,
	$H: typeid,
	$walk_part: proc(k: int, p: Parallel_Part, h: ^H, regs: ^hook.Regs, data: rawptr) -> Part_Result,
	data: rawptr,
	initial_held := u64(0),
) -> (err: tape.Error, done: bool) {
	if len(parts) < 2 || len(parts) > MAX_PARALLEL_PARTS {
		return nil, false
	}
	made_buf: Plan = ---
	plan, dups, class, made, prep_ok := parallel_prepare(target, T, format, tag, opts, uopts, caller, &made_buf)
	if !prep_ok {
		return nil, false
	}
	defer if made {
		destroy_temp_plan(plan)
	}
	root_rec := (^Record)(uintptr(plan.root) - size_of(Record))
	if root_rec.kind != .Slice && root_rec.kind != .Dynamic {
		return nil, false
	}
	pool := Block_Pool{backing = caller, limit = opts.budget.memory, held = initial_held}
	list := Parallel_List{owner = root_rec, dest = uintptr(target), depth = 1}
	ok := parallel_list_workers(src, format, rules, plan, list, parts, dups, uopts, opts, caller, class, &pool, made, H, walk_part, data)
	return nil, ok
}

// Parallel typed read for formats with nested/non-spine list roots (JSON, JSONC, JSON5, CBOR).
// Walks serially until opening a `.Slice`/`.Dynamic` target with a large remaining tail, splits that list into parts
// via `$split_list`, parses whole elements in parallel, gathers into the exact target slice, and walks the suffix
// serially via `$walk_suffix`. Any failure restores `target` cleanly and returns `done = false` so the caller reruns
// serially with exact error, path, and budget semantics.
@(require_results)
read_parallel_spine :: proc(
	src: []u8,
	target: rawptr,
	T: typeid,
	format: ^tape.Format,
	rules: ^tape.Rules,
	tag: string,
	opts: tape.Options,
	uopts: Unmarshal_Options,
	caller: runtime.Allocator,
	max_depth: int,
	$H: typeid,
	$walk_prefix: proc(src: []u8, opts: tape.Options, h: ^Probe_Reader(H), regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool),
	$split_list: proc(src: []u8, found: Parallel_List, opts: tape.Options, parts: []Parallel_Part, scratch: runtime.Allocator, data: rawptr) -> (n_parts: int, list_close: int, ok: bool),
	$walk_part: proc(k: int, p: Parallel_Part, found: Parallel_List, h: ^H, regs: ^hook.Regs, data: rawptr) -> Part_Result,
	$walk_suffix: proc(src: []u8, list_close: int, opens: []tape.Kind, opts: tape.Options, h: ^H, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context, data: rawptr) -> (u64, tape.Error, bool),
	data: rawptr,
) -> (err: tape.Error, done: bool) {
	if len(src) < PARALLEL_FROM {
		return nil, false
	}
	made_buf: Plan = ---
	plan, dups, class, made, prep_ok := parallel_prepare(target, T, format, tag, opts, uopts, caller, &made_buf)
	if !prep_ok {
		return nil, false
	}
	defer if made {
		destroy_temp_plan(plan)
	}
	pool := Block_Pool{backing = caller, limit = opts.budget.memory}
	scratch_backing := parallel_scratch_backing(opts, caller)
	lscratch := Locked_Scratch{backing = scratch_backing, pool = &pool}
	scratch := locked_scratch_allocator(&lscratch)
	prefix_block := Worker_Block{pool = &pool, last = -1, next = BLOCK_MIN}
	prefix_alloc := worker_block_allocator(&prefix_block) if class == .Blocks else caller
	frames: [64]Frame = ---
	flags := reader_flags(dups, uopts, made)
	ctx := context
	ctx.allocator = prefix_alloc
	probe: Probe_Reader(H)
	init_reader(&probe.inner, src, format, plan, flags, uopts.borrow_strings, uopts.path, target, prefix_alloc, caller, scratch, &ctx, frames[:])
	when H == Text_Reader {
		memo: hook.Expected_Memo = ---
		probe.expected = &memo
	}
	probe.min_tail = u64(PARALLEL_FROM)
	probe.max_depth = max_depth
	frames[0] = {b = u64(uintptr(&DEAD_BLOCK[1])), seen = SEEN_TARGET}
	// Always snapshot `target` before the prefix walk so any parallel or suffix abort restores caller-filled targets cleanly.
	before_buf: [128]u8 = ---
	size := uint(plan.size)
	if size <= len(before_buf) {
		probe.before = before_buf[:size]
	} else {
		block, berr := runtime.mem_alloc_non_zeroed(int(size), 1, scratch)
		if berr != nil || len(block) < int(size) {
			return nil, false
		}
		probe.before = block[:size]
	}
	if size > 0 {
		intrinsics.mem_copy_non_overlapping(raw_data(probe.before), target, int(size))
	}
	defer cleanup_reader(&probe.inner, len(before_buf))
	when H == Refusing_Reader {
		defer refusing_free(&probe.inner)
	}
	regs := hook.Regs{NO_LIMIT, u64(uintptr(plan.root)), u64(uintptr(target))}
	_, perr, _ := walk_prefix(src, opts, &probe, &regs, scratch, &probe.ctx)
	if probe.found.owner == nil {
		// No large list was opened: the prefix walk already read the entire text!
		when H == Refusing_Reader {
			perr = refusing_end(&probe.inner, perr, rules)
		}
		if perr == nil {
			perr = probe.err
		} else if .Dead not_in probe.flags {
			settle_open(&probe.inner, regs, probe.sp)
		}
		if pool.refused {
			undo_target(&probe.inner, target, scratch_backing)
			return nil, false
		}
		if perr != nil {
			// If anything failed (e.g. refusal/syntax error), restore target and let serial report exact error/budget.
			undo_target(&probe.inner, target, scratch_backing)
			return nil, false
		}
		return nil, true
	}
	if perr != nil || probe.err != nil || .Dead in probe.flags {
		if .Dead not_in probe.flags {
			settle_open(&probe.inner, regs, probe.sp)
		}
		undo_target(&probe.inner, target, scratch_backing)
		return nil, false
	}
	parts: [MAX_PARALLEL_PARTS]Parallel_Part
	n_parts, list_close, split_ok := split_list(src, probe.found, opts, parts[:], scratch, data)
	if !split_ok || n_parts < 2 {
		settle_open(&probe.inner, regs, probe.sp)
		undo_target(&probe.inner, target, scratch_backing)
		return nil, false
	}
	Spine_Part_Wrap :: struct {
		found: Parallel_List,
		data:  rawptr,
	}
	wrap_walk :: proc(k: int, p: Parallel_Part, h: ^H, regs: ^hook.Regs, wdata: rawptr) -> Part_Result {
		w := (^Spine_Part_Wrap)(wdata)
		return walk_part(k, p, w.found, h, regs, w.data)
	}
	wrap := Spine_Part_Wrap{found = probe.found, data = data}
	if !parallel_list_workers(src, format, rules, plan, probe.found, parts[:n_parts], dups, uopts, opts, caller, class, &pool, made, H, wrap_walk, &wrap) {
		settle_open(&probe.inner, regs, probe.sp)
		undo_target(&probe.inner, target, scratch_backing)
		return nil, false
	}
	// Close the list frame on the prefix reader and walk the suffix serially.
	probe.sp -= 1
	lf := &probe.frames[probe.sp]
	own := (^Record)(uintptr(lf.b) - size_of(Record))
	regs = {lf.a, lf.b, lf.c + u64(own.stride)}
	when H == Refusing_Reader {
		if len(probe.opens) > 0 {
			pop(&probe.opens)
		}
	}
	// Collect the container kinds of the still-open parent frames for the suffix walk.
	opens_buf: [64]tape.Kind
	n_opens := probe.sp - 1
	if n_opens > len(opens_buf) {
		settle_open(&probe.inner, regs, probe.sp)
		undo_target(&probe.inner, target, scratch_backing)
		return nil, false
	}
	for i in 0 ..< n_opens {
		owner := frame_owner(&probe.frames[i + 1])
		opens_buf[i] = .Object if (owner.kind == .Struct || owner.kind == .Required || owner.kind == .Map) else .Array
	}
	_, serr, _ := walk_suffix(src, list_close, opens_buf[:n_opens], opts, &probe.inner, &regs, scratch, &probe.ctx, data)
	when H == Refusing_Reader {
		serr = refusing_end(&probe.inner, serr, rules)
	}
	if serr == nil {
		serr = probe.err
	}
	if serr != nil || pool.refused {
		if .Dead not_in probe.flags {
			settle_open(&probe.inner, regs, probe.sp)
		}
		undo_target(&probe.inner, target, scratch_backing)
		return nil, false
	}
	return nil, true
}

// Parses `parts` in parallel into per-worker temporary lists, then gathers them into the exact target slice/dynamic
// array at `list.dest`. On any error/refusal/OOM, frees all worker allocations cleanly and returns false.
@(private)
parallel_list_workers :: proc(
	src: []u8,
	format: ^tape.Format,
	rules: ^tape.Rules,
	plan: ^Plan,
	list: Parallel_List,
	parts: []Parallel_Part,
	dups: tape.Duplicates,
	uopts: Unmarshal_Options,
	opts: tape.Options,
	caller: runtime.Allocator,
	class: Alloc_Class,
	pool: ^Block_Pool,
	made: bool,
	$H: typeid,
	$walk_part: proc(k: int, p: Parallel_Part, h: ^H, regs: ^hook.Regs, data: rawptr) -> Part_Result,
	data: rawptr,
) -> bool {
	n_parts := len(parts)
	elem_meta := &plan.meta[list.owner.meta]
	elem_size := int(elem_meta.size)
	elem_align := max(int(elem_meta.align), 1)
	scratch_backing := parallel_scratch_backing(opts, caller)
	lscratch := Locked_Scratch{backing = scratch_backing, pool = pool}
	// If `opts.scratch` is unset and no budget is active on a hosted build, `runtime.heap_allocator()` is already thread-safe with no lock.
	scratch := scratch_backing if opts.scratch.procedure == nil && opts.budget.memory == 0 && !(ODIN_DEFAULT_TO_NIL_ALLOCATOR || ODIN_DEFAULT_TO_PANIC_ALLOCATOR) else locked_scratch_allocator(&lscratch)
	outs: [MAX_PARALLEL_PARTS]Worker_Out
	flags := reader_flags(dups, uopts, made) + {.Worker_List}
	Job :: struct {
		src:       []u8,
		format:    ^tape.Format,
		rules:     ^tape.Rules,
		plan:      ^Plan,
		list:      Parallel_List,
		parts:     []Parallel_Part,
		outs:      []Worker_Out,
		flags:     Reader_Flags,
		borrow:    bool,
		caller:    runtime.Allocator,
		scratch:   runtime.Allocator,
		class:     Alloc_Class,
		pool:      ^Block_Pool,
		data:      rawptr,
	}
	worker :: proc(arg: rawptr, k: int) {
		j := (^Job)(arg)
		p := j.parts[k]
		part_bytes := max(p.to - p.from, 0)
		wblock := Worker_Block{
			pool = j.pool,
			last = -1,
			next = clamp(part_bytes / 4, BLOCK_MIN, BLOCK_INIT),
		}
		alloc := worker_block_allocator(&wblock) if j.class == .Blocks else j.caller
		frames: [64]Frame = ---
		ctx := context
		ctx.allocator = alloc
		hk_buf: [size_of(H) / size_of(u64)]u64 = ---
		hk := (^H)(&hk_buf[0])
		init_reader(hk, j.src, j.format, j.plan, j.flags, j.borrow, nil, nil, alloc, j.caller, j.scratch, &ctx, frames[:])
		when H == Text_Reader {
			memo: hook.Expected_Memo = ---
			hk.expected = &memo
		}
		// Copy the list record with kind `.Dynamic` so `publish_list` always records exact `cap` for scratch cleanup.
		worker_owner := j.list.owner^
		worker_owner.kind = .Dynamic
		// Frame 0: dead sentinel (without `SEEN_TARGET`, because all worker elements are fresh).
		// Frame 1: the parallel list frame, writing directly to `j.outs[k].list` on close or settle.
		frames[0] = {b = u64(uintptr(&DEAD_BLOCK[1]))}
		frames[1] = {
			a      = NO_LIMIT,
			b      = u64(uintptr(&WORKER_LIST_WRAPPER[1])),
			c      = 0,
			seen   = 0,
			data   = nil,
			owner  = &worker_owner,
			target = uintptr(&j.outs[k].list),
		}
		hk.sp = 2
		regs := hook.Regs{0, u64(uintptr(worker_owner.first)), 0}
		res := walk_part(k, p, hk, &regs, j.data)
		err := res.err
		when H == Refusing_Reader {
			err = refusing_end(hk, err, j.rules)
		}
		if err == nil {
			err = hk.err
		}
		// Ensure the worker's list header is published into `j.outs[k].list` (handles both open non-final parts and
		// error paths cleanly).
		if hk.sp >= 2 && .Dead not_in hk.flags {
			settle_open(&hk.reader, regs, hk.sp)
		}
		cleanup_reader(&hk.reader, 0)
		j.outs[k].err = err
		j.outs[k].astray = res.astray
	}
	job := Job {
		src     = src,
		format  = format,
		rules   = rules,
		plan    = plan,
		list    = list,
		parts   = parts,
		outs    = outs[:n_parts],
		flags   = flags,
		borrow  = uopts.borrow_strings,
		caller  = caller,
		scratch = scratch,
		class   = class,
		pool    = pool,
		data    = data,
	}
	hook.fan_each(opts.runner, n_parts, worker, &job)
	ok := !pool.refused
	total := 0
	for k in 0 ..< n_parts {
		if outs[k].err != nil || outs[k].astray {
			ok = false
		}
		outs[k].offset = total
		total += outs[k].list.len
	}
	final_data: rawptr
	final_bytes: []u8
	if ok && total > 0 && elem_size > 0 {
		need := total * elem_size
		aerr: runtime.Allocator_Error
		if class == .Blocks {
			final_bytes, aerr = pool_alloc_locked(pool, need, elem_align, false)
		} else {
			final_bytes, aerr = runtime.mem_alloc_non_zeroed(need, elem_align, caller)
		}
		if aerr != nil || len(final_bytes) < need {
			ok = false
		} else {
			final_data = raw_data(final_bytes)
		}
	}
	if !ok {
		// Release every element allocated on the heap in `.Direct` mode so zero memory leaks before serial retry.
		// `.Direct` only runs with `caller == runtime.heap_allocator()` and `opts.budget.memory == 0`, so using
		// `caller` for `rel.scratch` avoids partial `release` failure (and retry double-free) under tight `opts.scratch`.
		if class == .Direct && elem_meta.frees {
			elem_rec := &([^]Record)(list.owner.first)[-1]
			ctx := context
			ctx.allocator = caller
			rel := Reader {
				base      = raw_data(src),
				len       = u64(len(src)),
				plan      = plan,
				format    = format,
				allocator = caller,
				caller    = caller,
				scratch   = caller,
				ctx       = ctx,
			}
			for k in 0 ..< n_parts {
				l := outs[k].list
				if l.data == nil {
					continue
				}
				for i in 0 ..< l.len {
					_ = release(&rel, elem_rec, uintptr(l.data) + uintptr(i * elem_size), 0)
				}
			}
		}
		for k in 0 ..< n_parts {
			l := outs[k].list
			if l.data != nil {
				runtime.mem_free_with_size(l.data, l.cap * elem_size, scratch)
			}
		}
		return false
	}
	// Gather worker slices into the exact final buffer.
	if total > 0 && elem_size > 0 {
		total_bytes := total * elem_size
		if total_bytes >= 1 << 18 && n_parts >= 2 {
			Gather_Job :: struct {
				dst:       [^]u8,
				outs:      []Worker_Out,
				elem_size: int,
			}
			gather :: proc(arg: rawptr, k: int) {
				g := (^Gather_Job)(arg)
				l := g.outs[k].list
				if l.len > 0 {
					intrinsics.mem_copy_non_overlapping(g.dst[g.outs[k].offset * g.elem_size:], l.data, l.len * g.elem_size)
				}
			}
			gj := Gather_Job{dst = ([^]u8)(final_data), outs = outs[:n_parts], elem_size = elem_size}
			hook.fan_each(opts.runner, n_parts, gather, &gj)
		} else {
			dst := ([^]u8)(final_data)
			for k in 0 ..< n_parts {
				l := outs[k].list
				if l.len > 0 {
					intrinsics.mem_copy_non_overlapping(dst[outs[k].offset * elem_size:], l.data, l.len * elem_size)
				}
			}
		}
	}
	for k in 0 ..< n_parts {
		l := outs[k].list
		if l.data != nil {
			runtime.mem_free_with_size(l.data, l.cap * elem_size, scratch)
		}
	}
	if list.owner.kind == .Slice {
		(^runtime.Raw_Slice)(list.dest)^ = {final_data, total}
	} else {
		(^runtime.Raw_Dynamic_Array)(list.dest)^ = {final_data, total, total, caller}
	}
	return true
}

@(private)
reader_flags :: proc "contextless" (dups: tape.Duplicates, uopts: Unmarshal_Options, made: bool) -> (flags: Reader_Flags) {
	if dups == .First {
		flags += {.First}
	}
	if uopts.refuse_unknown {
		flags += {.Unknown}
	}
	if made {
		flags += {.Made}
	}
	return
}

@(private)
init_reader :: #force_inline proc(
	hk: ^$H,
	src: []u8,
	format: ^tape.Format,
	plan: ^Plan,
	flags: Reader_Flags,
	borrow: bool,
	path: ^[dynamic]tape.Step,
	target: rawptr,
	allocator, caller, scratch: runtime.Allocator,
	ctx: ^runtime.Context,
	frames: []Frame,
) {
	h := &hk.reader
	h^ = {
		base      = raw_data(src),
		len       = u64(len(src)),
		frames    = raw_data(frames),
		sp        = 1,
		room      = len(frames),
		borrow    = borrow,
		flags     = flags,
		plan      = plan,
		home      = raw_data(frames),
		format    = format,
		path      = path,
		target    = uintptr(target),
		allocator = allocator,
		caller    = caller,
		scratch   = scratch,
		ctx       = ctx^,
	}
	when H == Cells_Reader {
		hk.replay = {}
		hk.dropped = 0
		hk.taken = 0
		hk.alike = true
		hk.learn = .Before
	} else when H == Refusing_Reader {
		hk.keys = {}
		hk.opens = {}
		hk.hashed = {}
		hk.keys.allocator = scratch
		hk.opens.allocator = scratch
		hk.hashed.allocator = scratch
		hk.repeat = max(u64)
		hk.passing = 0
		hk.ends = false
		hk.value = false
		hk.done = false
		hk.refused = nil
	} else {
		// Expected_Memo lives on caller/worker stack in `Text_Reader`; point to nil? No, `Text_Reader` walks with
		// `.Expects` require a valid `^hook.Expected_Memo`. Allocate on caller stack via `set_expected_memo` or store
		// in `worker`. Handled below via a stack memo in callers that need it.
		hk.expected = nil
	}
}

// Restores `target` to its exact pre-read bytes from `h.before` and `h.held`, releasing anything allocated into it.
// Uses unbudgeted `undo_scratch` when supplied so rollback succeeds even after `pool.limit` has been exhausted.
@(private)
undo_target :: proc(h: ^Reader, target: rawptr, undo_scratch := runtime.Allocator{}) {
	saved := h.scratch
	if undo_scratch.procedure != nil {
		h.scratch = undo_scratch
	}
	defer h.scratch = saved
	root_rec := (^Record)(uintptr(h.plan.root) - size_of(Record))
	_ = reset(h, root_rec, uintptr(target), true)
}

@(private)
cleanup_reader :: proc(h: ^Reader, before_room: int) {
	if h.frames != h.home {
		runtime.mem_free_with_size(h.frames, h.room * size_of(Frame), h.scratch)
	}
	if h.map_keys != nil {
		path_alloc := h.path.allocator if h.path.allocator.procedure != nil else h.caller
		runtime.mem_free_with_size(raw_data(h.map_keys), len(h.map_keys) * size_of(tape.Token), path_alloc)
	}
	if h.zero != nil {
		runtime.mem_free_with_size(raw_data(h.zero), len(h.zero), h.scratch)
	}
	if len(h.before) > before_room {
		runtime.mem_free_with_size(raw_data(h.before), len(h.before), h.scratch)
	}
	if h.held != nil {
		held_free(h)
	}
}
