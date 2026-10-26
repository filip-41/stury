package csv_tests

// `each_record`'s fault policy over several pieces: the first faulty piece's fault is returned, which is the
// fault `records` ends on, and no piece past it is claimed. The caller's task returning false ends the claims.

import "core:sync"
import "core:testing"
import core "../../core"
import cs ".."
import host "../../host"

// The records around the fault line. The fault is a CR no LF follows, `.Bad_Char` at the CR.
@(private = "file")
LINE :: "alpha,beta,gamma,delta\n"

// `lines` records, the one numbered `fault_line` holding `bad\rline`, and the offset of its CR.
@(private = "file")
build_csv :: proc(lines, fault_line: int) -> (src: []byte, fault_at: u64) {
	out: [dynamic]byte
	for i in 0 ..< lines {
		if i == fault_line {
			fault_at = u64(len(out) + 3)
			append(&out, ..transmute([]byte)string("bad\rline\n"))
			continue
		}
		append(&out, ..transmute([]byte)string(LINE))
	}
	return out[:], fault_at
}

// A runner whose helpers never start: the caller claims every piece, in source order, so the last piece
// claimed is the last one run.
@(private = "file")
caller_runner :: proc() -> cs.Batch_Runner {
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
	errors: [dynamic]Maybe(cs.Error),
}

// Reads piece `k` to its end and records its number and its fault.
@(private = "file")
log_piece :: proc(data: rawptr, piece: ^cs.Records, k: int) -> bool {
	log := (^Batch_Log)(data)
	for _ in cs.next_record(piece) {}
	sync.lock(&log.lock)
	append(&log.pieces, k)
	append(&log.errors, piece.err)
	sync.unlock(&log.lock)
	return true
}

@(private = "file")
false_task :: proc(data: rawptr, _: ^cs.Records, _: int) -> bool {
	sync.atomic_add((^int)(data), 1)
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
test_csv_first_faulty_piece_stops_the_claims :: proc(t: ^testing.T) {
	src, fault_at := build_csv(46_000, 23_000)
	defer delete(src)
	testing.expectf(t, len(src) > 4 * core.BATCH_CHUNK, "%d bytes is not a multi-piece batch", len(src))
	want := cs.Error{kind = .Bad_Char, offset = fault_at}
	testing.expect_value(t, cs.validate(src), want)
	caller := caller_runner()
	pool: host.Batch_Pool
	host.batch_pool_init(&pool, 4)
	defer host.batch_pool_destroy(&pool)
	for runner in ([]^cs.Batch_Runner{nil, &caller, &pool.runner}) {
		log: Batch_Log
		defer delete(log.pieces)
		defer delete(log.errors)
		err := cs.each_record(src, log_piece, &log, {}, runner)
		testing.expectf(t, err == want, "%v, want %v", err, want)
		testing.expect(t, len(log.pieces) > 0)
		switch runner {
		case nil:
			testing.expect_value(t, len(log.pieces), 1)
			testing.expect_value(t, first_faulty(&log), 0)
		case &caller:
			// The caller claims in order, so the faulty piece is the last one claimed: every piece before it
			// ran and none after it did.
			bad := first_faulty(&log)
			testing.expectf(t, bad >= 0, "%d pieces, no fault", len(log.pieces))
			testing.expectf(t, bad > 0, "the fault was in the first piece")
			testing.expectf(t, bad == len(log.pieces) - 1, "%d pieces, faulty %d", len(log.pieces), bad)
			for k, i in log.pieces {
				testing.expectf(t, k == i, "piece %d ran as %d", i, k)
			}
		case &pool.runner:
			testing.expectf(t, len(log.pieces) > 1, "%d pieces", len(log.pieces))
		}

		verr := cs.validate(src, runner = runner)
		testing.expectf(t, verr == want, "validate: %v, want %v", verr, want)
	}
}

@(test)
test_csv_task_false_ends_the_claims :: proc(t: ^testing.T) {
	src, _ := build_csv(46_000, -1)
	defer delete(src)
	caller := caller_runner()
	for runner in ([]^cs.Batch_Runner{nil, &caller}) {
		calls: int
		err := cs.each_record(src, false_task, &calls, {}, runner)
		testing.expect(t, err == nil)
		testing.expectf(t, calls == 1, "%d calls", calls)
	}
}
