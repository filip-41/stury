package json_tests

// The demand matcher's key filter (first byte, then length and first 8 bytes) may only reject a member that
// no wanted key names. Each case puts members whose keys sit next to the wanted ones (same first byte, same
// head, a prefix, an escaped spelling) after a run of filler members and asserts the answers a plain compare
// would give, in every strictness and both resolutions, with and without the filler (which makes the walk
// take its members by the index) and at the root and one level in.

import json "../.."
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
Key_Filter_Case :: struct {
	// Members after the filler, as written: the last one ends the document unless `pad` is set.
	tail:       string,
	queries:    []string,
	// The value text each query answers under `.First` and `.Last`, "" is a miss.
	want_first: []string,
	want_last:  []string,
}

@(private = "file")
key_filter_cases := []Key_Filter_Case {
	// A key spelled with escapes matches its unescaped query. One that decodes elsewhere does not.
	{`"\u006b0048000":7`, {"k0048000"}, {"7"}, {"7"}},
	{`"k0048\u0030\u00300":7`, {"k0048000"}, {"7"}, {"7"}},
	{`"\u006b0048001":7`, {"k0048000"}, {""}, {""}},
	// The same key plain and escaped: first and last differ.
	{`"k0048000":1,"\u006b0048000":2`, {"k0048000"}, {"1"}, {"2"}},
	// Keys sharing the query's 8-byte head and differing after it, or by length.
	{`"k0048000abd":1,"k0048000ab":2,"k0048000abcd":3,"k0048000abc":4`, {"k0048000abc"}, {"4"}, {"4"}},
	{`"k0048000":1,"k00480000":2`, {"k0048000"}, {"1"}, {"1"}},
	{`"k00480000":2,"k0048000":1`, {"k0048000"}, {"1"}, {"1"}},
	// Same length, differing in the last byte of the head, and in each byte before it.
	{`"k0048001":1,"j0048000":2,"k0049000":3,"k0048000":4`, {"k0048000"}, {"4"}, {"4"}},
	// Keys shorter than 8 bytes, a key that is a prefix of another, and the empty key.
	{`"k":1,"kk":2,"kkk":3`, {"kk"}, {"2"}, {"2"}},
	{`"kkk":3,"k":1,"kk":2`, {"k"}, {"1"}, {"1"}},
	{`"k1":1,"k12":2,"k123":3,"k1234567":4,"k12345678":5`, {"k1234567"}, {"4"}, {"4"}},
	{`"k1":1,"k12":2,"k123":3,"k1234567":4,"k12345678":5`, {"k12345678"}, {"5"}, {"5"}},
	{`"":0,"k":1`, {""}, {"0"}, {"0"}},
	{`"k":1,"":0`, {""}, {"0"}, {"0"}},
	{`"k":1`, {""}, {""}, {""}},
	// A key with the head's bytes but a wanted key longer than the key, and a query longer than 8 bytes.
	{`"k004800":1,"k0048000":2`, {"k00480000"}, {""}, {""}},
	{`"k0048000":1`, {"k00480000"}, {""}, {""}},
	// Whitespace between the key and its colon, and after the colon.
	{`"k0048000" :1,"k0048001"  : 2`, {"k0048000"}, {"1"}, {"1"}},
	{`"k0048000"
	:1`, {"k0048000"}, {"1"}, {"1"}},
	// Non-ASCII keys, whose bytes are above 0x7f.
	{`"k\u00e9x":1,"kéx":2`, {"kéx"}, {"1"}, {"2"}},
	{`"kéx":1,"kéy":2`, {"kéy"}, {"2"}, {"2"}},
	// A wanted key holding a quote: the document's `a` ends where the query's bytes go on.
	{`"a":1,"a\"b":2`, {"a\"b"}, {"2"}, {"2"}},
	{`"a":1,"a\":b":2`, {"a\":b"}, {"2"}, {"2"}},
	{`"a":1`, {"a\":b"}, {""}, {""}},
	// Several wanted keys, within the filter's table and past it.
	{`"k0048000":1,"k0048001":2,"x":3`, {"k0048000", "k0048001"}, {"1", "2"}, {"1", "2"}},
	{`"k0048000":1,"k0048001":2,"x":3`, {"k0048001", "nope", "x"}, {"2", "", "3"}, {"2", "", "3"}},
	{`"k0048000":1,"k0048001":2,"k":3,"":4`, {"k0048000", "k0048001", "k", ""}, {"1", "2", "3", "4"}, {"1", "2", "3", "4"}},
	{`"k0048000":1,"k0048001":2,"k":3,"\u006b0048004":9`, {"k0048000", "k0048001", "k", "", "k0048004"}, {"1", "2", "3", "", "9"}, {"1", "2", "3", "", "9"}},
	{`"k0048000":1,"k0048000":2`, {"k0048000", "k0048000"}, {"1", "1"}, {"2", "2"}},
	// A last member whose key is within 8 bytes of the end of the buffer.
	{`"k":1`, {"k"}, {"1"}, {"1"}},
	{`"kk":12`, {"kk"}, {"12"}, {"12"}},
	{`"k0048000":1`, {"k0048000"}, {"1"}, {"1"}},
	{`"k0048000abc":1`, {"k0048000abc"}, {"1"}, {"1"}},
}

@(test)
test_demand_key_filter :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for fill in ([]int{0, 700}) {
		for nested in ([]bool{false, true}) {
			for c, ci in key_filter_cases {
				b: strings.Builder
				strings.builder_init(&b, context.temp_allocator)
				strings.write_string(&b, `{"a":{` if nested else "{")
				// Filler keys open with the wanted keys' first byte and have the length of the common one.
				for i in 0 ..< fill {
					fmt.sbprintf(&b, `"k1%06d":%d,`, i, i)
				}
				strings.write_string(&b, c.tail)
				strings.write_string(&b, `}}` if nested else "}")
				src := strings.to_string(b)

				paths := make([]json.Path, len(c.queries), context.temp_allocator)
				for q, i in c.queries {
					steps := make([]json.Step, 2 if nested else 1, context.temp_allocator)
					steps[len(steps) - 1] = json.Name(q)
					if nested {
						steps[0] = json.Name("a")
					}
					paths[i] = json.Path{steps = steps}
				}
				for level in ([]json.Strictness{.Strict, .Structural, .Lazy}) {
					for mode in ([]json.Duplicates{.First, .Last}) {
						if level == .Lazy && mode == .Last {
							continue // a stopping walk needs the first occurrence
						}
						r := paths_run(raw(src), paths, level, mode)
						defer json.destroy(&r.req)
						want := c.want_first if mode == .First else c.want_last
						testing.expectf(t, r.err == nil, "fill %d nested %v case %d: %v", fill, nested, ci, r.err)
						for _, i in c.queries {
							got := ""
							for a in r.answers {
								if a.query == u32(i) && a.outcome == .Found {
									got = src[a.lo:a.hi]
								}
							}
							testing.expectf(
								t,
								got == want[i],
								"fill %d nested %v %v %v case %d query %q: got %q want %q in %q",
								fill, nested, level, mode, ci, c.queries[i], got, want[i], src[max(0, len(src) - 120):],
							)
						}
					}
				}
			}
		}
	}
}
