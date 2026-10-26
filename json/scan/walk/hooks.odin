package walk

import "base:intrinsics"

// Format_Hooks is the table of scanner procedures that this package's matchers call; this package cannot import
// the scanner. There is one read-only table per dialect (`json/scan/dialect.odin`: `FORMAT_HOOKS_JSONC`, `FORMAT_HOOKS_JSON5`).
// Each scan holds a pointer to its dialect's table (`Query_Ctx.hooks`), so concurrent scans share it without
// writing it.
Format_Hooks :: struct {
	escaped_key_equals: proc(src: []byte, lo, hi: u64, want: string) -> bool,
	// Validates values when `ctx.walk_judged`, else only locates. A refused append is on `ctx.oom`.
	path_subwalk: proc(s: ^Scanner, ctx: ^Query_Ctx, max_depth: u64, halted: ^bool) -> Maybe(Error),
	dom_unescape_into: proc(out: []byte, src: []byte, lo, hi: u64, first_esc: u64) -> int,
}

// A key without an escape is its own decoded text, so it is compared as written here, inline, between the
// one-byte delimiters every key token carries. Only an escaped key needs the format's decoder behind the hook.
key_equals_hooked :: #force_inline proc(hooks: ^Format_Hooks, src: []byte, lo, hi: u64, escaped: bool, want: string) -> bool {
	#no_bounds_check if !escaped {
		return hi >= lo + 2 && hi - lo - 2 == u64(len(want)) && spelled_equals(src[lo + 1:hi - 1], want)
	}
	return hooks.escaped_key_equals(src, lo, hi, want)
}

// Two equal-length byte strings compared without a call. Below 8 bytes a word load could leave either string,
// so the bytes are compared one at a time. From 8 to 16 bytes two overlapping words cover both strings, and
// neither load leaves them.
@(private = "file")
spelled_equals :: #force_inline proc(got: []byte, want: string) -> bool {
	n := len(want)
	#no_bounds_check {
		if n < 8 {
			for i in 0 ..< n {
				if got[i] != want[i] {
					return false
				}
			}
			return true
		}
		if n > 16 {
			return string(got) == want
		}
		g, w := raw_data(got), raw_data(want)
		return intrinsics.unaligned_load((^u64)(g)) == intrinsics.unaligned_load((^u64)(w)) &&
			intrinsics.unaligned_load((^u64)(g[n - 8:])) == intrinsics.unaligned_load((^u64)(w[n - 8:]))
	}
}
