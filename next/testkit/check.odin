// Shared streaming-vs-document schema check parity helper for format test suites.
package testkit

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/schema/check"

// Checks that streaming `r_s` and `r_ss` (with `sink_s`) agree with `reads.build` + `check.check_document` (both
// without and with a sink) on `src` against `plan`. Takes ownership of `r_s`, `r_ss`, and `sink_s` and destroys them.
check_parity :: proc(
	t: ^testing.T, plan: ^check.Plan, reads: ^tape.Reads, f: ^tape.Format, src: []u8, want_valid: bool,
	r_s, r_ss: check.Result, sink_s: ^check.Sink,
	opts := check.Options{}, build_opts := tape.Options{}, check_err := false, loc := #caller_location,
) {
	r_s, r_ss := r_s, r_ss
	defer check.result_destroy(&r_s)
	defer check.result_destroy(&r_ss)
	defer check.sink_destroy(sink_s)

	testing.expectf(t, r_s.valid == want_valid, "%s stream: got %v want %v", f.name, r_s.valid, want_valid, loc = loc)
	testing.expect_value(t, r_ss.valid, want_valid, loc = loc)

	doc, berr := reads.build(f, src, build_opts, context.allocator)
	testing.expect_value(t, berr, nil, loc = loc)
	defer tape.destroy(&doc)

	r_d := check.check_document(&doc, plan, opts)
	defer check.result_destroy(&r_d)
	testing.expect_value(t, r_d.valid, want_valid, loc = loc)

	sink_d: check.Sink
	check.sink_init(&sink_d)
	defer check.sink_destroy(&sink_d)
	r_ds := check.check_document(&doc, plan, opts, &sink_d)
	defer check.result_destroy(&r_ds)
	testing.expect_value(t, r_ds.valid, want_valid, loc = loc)
	testing.expect_value(t, len(sink_s.entries), len(sink_d.entries), loc = loc)

	if check_err && !want_valid {
		testing.expect_value(t, r_s.err.kind, r_d.err.kind, loc = loc)
		testing.expect_value(t, r_s.err.keyword, r_d.err.keyword, loc = loc)
	}
}
