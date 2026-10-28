package json_tests

import "core:testing"
import "../../scan/walk"

// Returns a demand over `keys`, prepared as a scan prepares it.
@(private = "file")
head_demand :: proc(ctx: ^walk.Query_Ctx, keys: []string, out: []walk.Field_Value) {
	walk.demand_prepare(ctx, walk.Demand_Spec{keys = keys, out = out}, .First, context.allocator)
}

// The head filter rejects only keys that cannot equal the one wanted key, passes any key it cannot decide (the
// full compare checks length), and never reads past the buffer.
@(test)
test_demand_head_may_match :: proc(t: ^testing.T) {
	ctx := new(walk.Query_Ctx, context.temp_allocator)
	out: [5]walk.Field_Value
	Case :: struct {
		keys: []string,
		src:  string, // the key under test is at offset 0, including its quotes
		want: bool,
	}
	cases := []Case {
		// One key: equal, differing in the head, shorter, and longer with the same head.
		{{"k0048000"}, `"k0048000":1,`, true},
		{{"k0048001"}, `"k0048000":1,`, false},
		{{"k0048000"}, `"k0048001":1,`, false},
		{{"k0048000"}, `"j0048000":1,`, false},
		{{"k0048000"}, `"k004800":1,00`, false},
		{{"k0048000"}, `"k00480000":1,`, true},
		// A wanted key longer than 8 bytes: the full compare decides among keys sharing the first 8.
		{{"k0048000abc"}, `"k0048000abd":1,`, true},
		{{"k0048000abc"}, `"k0048001abc":1,`, false},
		// Short wanted keys: only their own bytes count, and a key that is a prefix of another differs by its quote.
		{{"k"}, `"k":1,0000`, true},
		{{"k"}, `"kk":1,000`, true},
		{{"kk"}, `"k":1,0000`, false},
		{{""}, `"":1,00000`, true},
		{{""}, `"k":1,0000`, true},
		// Not exactly one key: no filter.
		{{"a", "k0048000"}, `"zz":1,0000`, true},
		{{"a", "b", "c", "d", "e"}, `"nope":1,000`, true},
		{{}, `"nope":1,000`, true},
		// A key whose 8-byte load would pass the buffer's end is left to the full compare.
		{{"k"}, `"x":1`, true},
		{{"k0048000"}, `"k00480"`, true},
	}
	for c, i in cases {
		head_demand(ctx, c.keys, out[:len(c.keys)])
		testing.expectf(t, walk.demand_head_may_match(ctx, transmute([]u8)c.src, 0) == c.want, "case %d %v %q", i, c.keys, c.src)
	}
}

// A `.Last` run settles early only when no step is a `Name`. An index-then-name path holds its answer until the
// root closes (`path_prefix_is_deterministic`), so it cannot stop early.
@(test)
test_last_settles_early_on_indices_only :: proc(t: ^testing.T) {
	Case :: struct {
		steps: []walk.Step,
		want:  bool,
	}
	for c in ([]Case{{{walk.Index(0), walk.Index(1)}, true}, {{walk.Index(0), walk.Name("a")}, false}, {{walk.Name("a"), walk.Index(0)}, false}}) {
		run := walk.Path_Run{steps = c.steps, mode = .Last}
		testing.expectf(t, walk.path_run_may_settle_early(&run) == c.want, "%v: want %v", c.steps, c.want)
	}
}
