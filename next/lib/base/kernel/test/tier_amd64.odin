#+build amd64
package kernel_tests

import "core:sys/info"
import "core:testing"
import k "stury:lib/base/kernel"
import "stury:testkit"

// The tier a build without `-define:TIER` picks is the one the CPU supports, so runtime detection runs there.
@(test)
tier_matches_the_cpu :: proc(t: ^testing.T) {
	testkit.deadline(t)
	forced :: #config(TIER, -1)
	want: k.Tier
	when forced >= 0 {
		want = k.Tier(forced)
	} else {
		v3 :: info.CPU_Features{.avx, .avx2, .bmi1, .bmi2, .popcnt, .pclmulqdq}
		want = .V3 if v3 <= info.cpu_features() else .V2
	}
	testing.expect_value(t, k.tier(), want)
}
