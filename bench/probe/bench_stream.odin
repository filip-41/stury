package main

// The streaming lane (`streaming_records`) times NDJSON windows through `validate_records` against one call
// on the whole file, each from open to verdict. `main` runs it before loading any fixture, so its RSS is the
// process's own high-water mark, not growth over a loaded copy.

import host "stury:host"
import json "stury:json"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:time"

// Times the stream arm, then the whole-file arm. The stream arm runs all its iterations first because RSS is
// a high-water mark, so its reading is taken before the whole file has been resident. `peak_rss_mb` is the
// stream arm's, in MiB. The arms run in separate passes, so drift between them is not compensated.
bench_stream :: proc(file: string) -> bool {
	path, found := fixture_path(file)
	if !found {
		return false
	}
	pool: host.Batch_Pool
	host.batch_pool_init(&pool)
	defer host.batch_pool_destroy(&pool)
	times: [2][TIMED_ITERS]i64
	rss: [2]u64
	size: [2]int
	for arm in 0 ..< 2 {
		for iter in -WARMUP_ITERS ..< TIMED_ITERS {
			t := time.tick_now()
			pass := arm == 0 ? stream_pass : whole_pass
			n, ok := pass(path, &pool.runner)
			took := i64(time.tick_since(t))
			if !ok {
				return false
			}
			size[arm] = n
			if iter >= 0 {
				times[arm][iter] = took
			}
		}
		rss[arm] = rss_peak()
	}
	if size[0] != size[1] {
		fmt.eprintf("the stream read %d bytes, the file holds %d\n", size[0], size[1])
		return false
	}
	MIB :: 1024 * 1024.0
	fmt.printf("peak_rss_mb=%.4g gb_per_s=%.4g whole_rss_mb=%.4g whole_gb_per_s=%.4g\n",
		f64(rss[0]) / MIB, f64(size[0]) / f64(median(times[0])),
		f64(rss[1]) / MIB, f64(size[1]) / f64(median(times[1])))
	return true
}

// A line wider than this fails the lane rather than doubling the window forever.
STREAM_MAX_WINDOW :: 1024 * 1024 * 1024

// Validates the NDJSON file at `path` one window of whole lines at a time. The window is 4 MiB and doubles to
// hold a longer line, up to STREAM_MAX_WINDOW. Returns the bytes validated, or false on a read error or fault.
stream_pass :: proc(path: string, runner: ^json.Batch_Runner) -> (n: int, ok: bool) {
	f, ferr := os.open(path)
	if ferr != nil {
		return 0, false
	}
	defer os.close(f)
	buf := make([]byte, 4 * 1024 * 1024)
	defer delete(buf)
	have := 0
	for eof := false; !eof || have > 0; {
		for !eof && have < len(buf) {
			k, err := os.read(f, buf[have:])
			have += k
			eof = err == io.Error.EOF
			if err != nil && !eof {
				return 0, false
			}
		}
		cut := have if eof else bytes.last_index_byte(buf[:have], '\n') + 1
		if cut == 0 {
			if len(buf) >= STREAM_MAX_WINDOW {
				return 0, false
			}
			grown := make([]byte, 2 * len(buf))
			copy(grown, buf[:have])
			delete(buf)
			buf = grown
			continue
		}
		faults, err := json.validate_records(buf[:cut], .NDJSON, runner)
		clean := err == nil && len(faults) == 0
		delete(faults)
		if !clean {
			return 0, false
		}
		n += cut
		copy(buf, buf[cut:have])
		have -= cut
	}
	return n, true
}

whole_pass :: proc(path: string, runner: ^json.Batch_Runner) -> (n: int, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return 0, false
	}
	defer delete(data)
	faults, verr := json.validate_records(data, .NDJSON, runner)
	clean := verr == nil && len(faults) == 0
	delete(faults)
	return len(data), clean
}
