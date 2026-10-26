#+build amd64
package json_tests

import "core:os"
import "core:testing"
import index "../../scan/index"

// With STURY_REQUIRE_WIDE set, a processor that lacks a wide path is a failure, not a skip: CI sets it on the
// run meant to execute those routes, so a runner without them cannot pass by not running them. "avx2" requires
// the AVX2 index, any other value (conventionally "avx512") both it and the AVX-512BW routes.
wide_required :: proc() -> (avx2: bool, avx512: bool) {
	v, set := os.lookup_env("STURY_REQUIRE_WIDE", context.temp_allocator)
	return set, set && v != "avx2"
}

@(test)
test_wide_paths_present_when_required :: proc(t: ^testing.T) {
	avx2, avx512 := wide_required()
	testing.expect(t, !avx2 || index.avx2_ok(), "STURY_REQUIRE_WIDE: no AVX2")
	testing.expect(t, !avx512 || index.wide_ok(), "STURY_REQUIRE_WIDE: no AVX-512BW (or SCAN_WIDE=false or SCAN_WIDE_512=false)")
}
