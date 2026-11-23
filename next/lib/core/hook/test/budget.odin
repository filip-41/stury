package hook_test

import "base:runtime"
import "core:mem"
import "core:testing"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"

// A memory budget counts each block it allocates, a resize by its change and a free by its size, and refuses a block
// that takes it one byte past the limit.
@(test)
memory_budget_counts_what_it_holds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	m := hook.Memory_Budget {
		backing = context.allocator,
		limit   = 100,
	}
	a := hook.memory_budget(&m)
	first, err := runtime.mem_alloc(60, 8, a)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.held, 60)
	_, err = runtime.mem_alloc(41, 8, a)
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, m.refused)
	testing.expect_value(t, m.held, 60)
	m.refused = false
	second, serr := runtime.mem_alloc(40, 8, a)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, m.held, 100)
	testing.expect(t, !m.refused)
	// A shrink gives bytes back, and a growth is counted by its change.
	second, serr = runtime.mem_resize(raw_data(second), 40, 10, 8, a)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, m.held, 70)
	_, err = runtime.mem_resize(raw_data(second), 10, 41, 8, a)
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, m.held, 70)
	second, serr = runtime.mem_resize(raw_data(second), 10, 40, 8, a)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, m.held, 100)
	// A free gives its block back.
	testing.expect_value(t, runtime.mem_free_with_size(raw_data(second), 40, a), nil)
	testing.expect_value(t, m.held, 60)
	third, terr := runtime.mem_alloc(40, 8, a)
	testing.expect_value(t, terr, nil)
	testing.expect_value(t, m.held, 100)
	testing.expect_value(t, runtime.mem_free_with_size(raw_data(third), 40, a), nil)
	testing.expect_value(t, runtime.mem_free_with_size(raw_data(first), 60, a), nil)
	testing.expect_value(t, m.held, 0)
}

// A read's error names the budget only when the budget made the last refusal: a block the budget refused, then a
// smaller one the backing refused, ends in the backing's error.
@(test)
memory_budget_names_the_last_refusal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: mem.Arena
	buffer: [64]u8
	mem.arena_init(&arena, buffer[:])
	m := hook.Memory_Budget {
		backing = mem.arena_allocator(&arena),
		limit   = 1024,
	}
	a := hook.memory_budget(&m)
	_, err := runtime.mem_alloc(2048, 8, a)
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, hook.memory_budget_error(&m, err) == tape.Error(tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}))
	_, err = runtime.mem_alloc(512, 8, a)
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, hook.memory_budget_error(&m, err) == tape.Error(runtime.Allocator_Error.Out_Of_Memory))
}

// Freeing everything leaves a budget holding nothing.
@(test)
memory_budget_frees_all_at_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: mem.Arena
	buffer: [1024]u8
	mem.arena_init(&arena, buffer[:])
	m := hook.Memory_Budget {
		backing = mem.arena_allocator(&arena),
		limit   = 100,
	}
	a := hook.memory_budget(&m)
	_, err := runtime.mem_alloc(70, 8, a)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.held, 70)
	testing.expect_value(t, runtime.mem_free_all(a), nil)
	testing.expect_value(t, m.held, 0)
	_, err = runtime.mem_alloc(100, 8, a)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, m.held, 100)
}

// A budget with no backing allocator gives nothing and holds nothing.
@(test)
memory_budget_without_a_backing_gives_nothing :: proc(t: ^testing.T) {
	testkit.deadline(t)
	m := hook.Memory_Budget{limit = 100}
	p, err := runtime.mem_alloc(8, 8, hook.memory_budget(&m))
	testing.expect(t, p == nil && err == nil && m.held == 0)
}

// Only an allocation the budget refused is a budget error.
@(test)
memory_budget_names_its_own_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	refused := hook.Memory_Budget{refused = true}
	other := hook.Memory_Budget{}
	exceeded := tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}
	testing.expect_value(t, hook.memory_budget_error(&refused, runtime.Allocator_Error.Out_Of_Memory), tape.Error(exceeded))
	testing.expect_value(t, hook.memory_budget_error(&other, runtime.Allocator_Error.Out_Of_Memory), tape.Error(runtime.Allocator_Error.Out_Of_Memory))
	testing.expect_value(t, hook.memory_budget_error(&refused, nil), nil)
	fault := tape.Fault{at = 3, kind = .Bad_Char}
	got, is_fault := hook.memory_budget_error(&refused, fault).(tape.Fault)
	testing.expect(t, is_fault && got.at == 3 && got.kind == .Bad_Char)
	steps := tape.Exceeded{at = 5, kind = .Steps}
	testing.expect_value(t, hook.memory_budget_error(&refused, steps), tape.Error(steps))
}

// Two budgets that are peers hold one limit between them, whatever each one's backing.
@(test)
memory_budget_peers_share_a_limit :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a, b: hook.Memory_Budget
	a = {backing = context.allocator, limit = 100, peer = &b}
	b = {backing = context.allocator, limit = 100, peer = &a}
	first, err := runtime.mem_alloc(60, 8, hook.memory_budget(&a))
	testing.expect_value(t, err, nil)
	_, err = runtime.mem_alloc(41, 8, hook.memory_budget(&b))
	testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
	testing.expect(t, b.refused && !a.refused)
	testing.expect_value(t, hook.memory_budget_error(&a, runtime.Allocator_Error.Out_Of_Memory), tape.Error(tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}))
	second, serr := runtime.mem_alloc(40, 8, hook.memory_budget(&b))
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, runtime.mem_free_with_size(raw_data(first), 60, hook.memory_budget(&a)), nil)
	testing.expect_value(t, runtime.mem_free_with_size(raw_data(second), 40, hook.memory_budget(&b)), nil)
}
