package json_tests

// `each_record`'s fault policy over several pieces: the first framing fault in byte order is returned, and the
// pieces after it are still claimed. The caller's task returning false ends the claims.

import "core:slice"
import "core:sync"
import "core:testing"
import core "../../../core"
import host "../../../host"
import json "../.."

// One NDJSON record. The BOM a fault line starts with is `.Bad_Char` at the record's offset.
@(private = "file")
RECORD :: `{"id":123456,"name":"abcdefghijklmnopqrstuvwxyz"}`

// `lines` records, a byte order mark before each record numbered in `fault_lines`, and the offsets of those
// marks.
@(private = "file")
build_stream :: proc(lines: int, fault_lines: []int) -> (src: []byte, faults: [dynamic]u64) {
	out: [dynamic]byte
	for i in 0 ..< lines {
		if slice.contains(fault_lines, i) {
			append(&faults, u64(len(out)))
			append(&out, 0xEF, 0xBB, 0xBF)
		}
		append(&out, ..transmute([]byte)string(RECORD))
		append(&out, '\n')
	}
	return out[:], faults
}

// A runner whose helpers never start: the caller claims every piece, in source order, so the last piece
// claimed is the last one run.
@(private = "file")
caller_runner :: proc() -> json.Batch_Runner {
	return {
		threads = 64,
		start = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {},
		finish = proc(data: rawptr) {},
	}
}

@(private = "file")
Batch_Log :: struct {
	lock:   sync.Mutex,
	pieces: [dynamic]int,
	errors: [dynamic]Maybe(json.Error),
}

// Reads piece `k` to its end and records its number and its fault.
@(private = "file")
log_piece :: proc(log: ^Batch_Log, piece: ^json.Records, k: int) -> bool {
	for _ in json.next_record(piece) {}
	sync.lock(&log.lock)
	append(&log.pieces, k)
	append(&log.errors, piece.err)
	sync.unlock(&log.lock)
	return true
}

@(private = "file")
false_task :: proc(n: ^int, _: ^json.Records, _: int) -> bool {
	sync.atomic_add(n, 1)
	return false
}

// The first faulty piece's index in the log, or -1.
@(private = "file")
first_faulty :: proc(log: ^Batch_Log) -> int {
	for e, i in log.errors {
		if e != nil {
			return i
		}
	}
	return -1
}

@(test)
test_ndjson_first_fault_is_in_byte_order_and_claims_on :: proc(t: ^testing.T) {
	fault_lines := []int{10_000, 15_000}
	src, faults := build_stream(20_000, fault_lines)
	defer delete(src)
	defer delete(faults)
	testing.expectf(t, len(src) > 4 * core.BATCH_CHUNK, "%d bytes is not a multi-piece batch", len(src))
	testing.expect_value(t, len(faults), 2)
	want := json.Error{kind = .Bad_Char, offset = faults[0]}
	caller := caller_runner()
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.destroy(&pool)
	for runner in ([]^json.Batch_Runner{nil, &caller, &pool.runner}) {
		log: Batch_Log
		defer delete(log.pieces)
		defer delete(log.errors)
		err := json.each_record(src, log_piece, &log, {framing = .NDJSON}, runner)
		// Both faults are noted: the first in byte order wins, whichever piece finishes first.
		testing.expectf(t, err == want, "%v, want %v", err, want)
		testing.expect(t, len(log.pieces) > 0)
		switch runner {
		case nil:
			testing.expect_value(t, len(log.pieces), 1)
			testing.expect_value(t, first_faulty(&log), 0)
		case &caller:
			// The caller claims in order, so the log's last piece is the last one claimed, and it comes
			// after the first faulty one.
			testing.expect(t, len(log.pieces) > 2)
			bad := first_faulty(&log)
			testing.expectf(t, bad >= 0 && bad < len(log.pieces) - 1, "%d pieces, faulty %d", len(log.pieces), bad)
			testing.expect(t, log.errors[bad] == want)
		case &pool.runner:
			testing.expectf(t, len(log.pieces) > 1, "%d pieces", len(log.pieces))
			testing.expectf(t, first_faulty(&log) >= 0, "no piece reported the fault")
		}

		faults_seen, verr := json.validate_records(src, {framing = .NDJSON}, runner)
		defer delete(faults_seen)
		testing.expectf(t, verr == want, "validate_records: %v, want %v", verr, want)
	}
}

@(test)
test_ndjson_task_false_ends_the_claims :: proc(t: ^testing.T) {
	src, faults := build_stream(20_000, {})
	defer delete(src)
	defer delete(faults)
	caller := caller_runner()
	for runner in ([]^json.Batch_Runner{nil, &caller}) {
		calls: int
		err := json.each_record(src, false_task, &calls, {framing = .NDJSON}, runner)
		testing.expect(t, err == nil)
		testing.expectf(t, calls == 1, "%d calls", calls)
	}
}
