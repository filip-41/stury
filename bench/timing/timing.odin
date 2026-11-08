// The sampling rule of every probe: WARMUP untimed calls, then TIMED timed ones, and the mean of the two middle
// samples as the median. The peers follow the same rule in their own languages.
package timing

import "core:slice"

WARMUP :: 2
TIMED :: 10

// Sorts `samples`, fastest first, and returns the median.
median :: proc(samples: ^[TIMED]i64) -> i64 {
	slice.sort(samples[:])
	return (samples[(TIMED - 1) / 2] + samples[TIMED / 2]) / 2
}
