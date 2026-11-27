#+build darwin, linux, freebsd, openbsd, netbsd
package testkit

import "base:runtime"
import "core:sys/posix"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The stack a thread spends before its first read, on its start and the job's call.
THREAD_START :: 16 * 1024

// The stack a sanitizer's build adds to a read's, whose frames keep a slot and a redzone for each local of the procs
// they inline, which the reads' stated stack does not count.
SANITIZER_STACK :: 32 * 1024 when ODIN_SANITIZER_FLAGS != {} else 0

Stack_Read :: #type proc(read: int, text: []u8) -> bool

@(private)
Stack_Job :: struct {
	ctx:  runtime.Context,
	run:  Stack_Read,
	read: int,
	text: []u8,
	ok:   bool,
}

@(private)
stack_job :: proc "c" (arg: rawptr) -> rawptr {
	job := (^Stack_Job)(arg)
	context = job.ctx
	job.ok = job.run(job.read, job.text)
	return nil
}

// Runs `run(read, text)` for each `read` below `reads`, each on a thread of `stack` bytes, and expects it to give true.
// A `stack` below the system's least thread stack (128 KiB on Linux arm64) is raised to it, and a sanitizer's build
// adds `SANITIZER_STACK`. `what` names the text in a failure.
expect_reads_on_thread :: proc(t: ^testing.T, stack: uint, reads: int, text: []u8, what: string, run: Stack_Read, loc := #caller_location) {
	size := stack + SANITIZER_STACK
	if least := posix.sysconf(._THREAD_STACK_MIN); least > 0 {
		size = max(size, uint(least))
	}
	attr: posix.pthread_attr_t
	posix.pthread_attr_init(&attr)
	defer posix.pthread_attr_destroy(&attr)
	testing.expect_value(t, posix.pthread_attr_setstacksize(&attr, size), posix.Errno.NONE, loc = loc)
	for read in 0 ..< reads {
		job := Stack_Job{context, run, read, text, false}
		thread: posix.pthread_t
		testing.expect_value(t, posix.pthread_create(&thread, &attr, stack_job, &job), posix.Errno.NONE, loc = loc)
		posix.pthread_join(thread, nil)
		testing.expectf(t, job.ok, "read %d %s stack %d", read, what, size, loc = loc)
	}
}

// The reads of a nested text past those every format's own deep test makes, `read` 0 to `DEEP_READS - 1`: a query of
// `paths` over its document, a scan of `paths`, the records of the container `at` reaches under `framing`, and a
// clone of its document. `paths` descend, so each read visits every level.
deep_read :: proc(read: int, reads: ^tape.Reads, f: ^tape.Format, text: []u8, opts: tape.Options, paths: [][]tape.Step, framing: tape.Framing, at: []tape.Step) -> bool {
	d, derr := tape.demand_of(paths)
	defer tape.destroy(&d)
	doc: tape.Document
	err: tape.Error
	if read == 0 || read == 3 {
		doc, err = reads.build(f, text, opts, context.allocator)
	}
	defer tape.destroy(&doc)
	if derr != nil || err != nil {
		return false
	}
	switch read {
	case 0:
		q, qerr := build.query({&doc, nil}, &d, opts)
		defer tape.destroy(&q)
		return qerr == nil && q.partial != nil && len(q.partial.answers) > 0
	case 1:
		s, serr := reads.scan(f, text, &d, {}, opts, context.allocator)
		defer tape.destroy(&s)
		return serr == nil
	case 2:
		r, rerr := reads.records(f, text, framing, opts, at, context.allocator)
		if rerr != nil {
			return false
		}
		defer tape.destroy_records(r)
		out: [4]tape.Record
		for tape.records_validate(r, out[:]) == len(out) {}
		return r.err == nil && r.index > 0
	case:
		c, cerr := tape.clone_document(&doc)
		defer tape.destroy(&c)
		return cerr == nil && len(c.nodes) == len(doc.nodes)
	}
}

DEEP_READS :: 4

// Runs the 4 basic reads (0: validate, 1: build, 2: find `find_path`, 3: scan `scan_paths`) followed by
// `deep_read` (4..7: query, scan `deep_paths`, records at `at`, clone).
deep_core_read :: proc(
	read: int, reads: ^tape.Reads, f: ^tape.Format, text: []u8, opts: tape.Options,
	find_path: []tape.Step, scan_paths, deep_paths: [][]tape.Step, framing: tape.Framing, at: []tape.Step,
) -> bool {
	switch read {
	case 0:
		return reads.validate(f, text, opts, context.allocator) == nil
	case 1:
		doc, err := reads.build(f, text, opts, context.allocator)
		tape.destroy(&doc)
		return err == nil
	case 2:
		answer, err := reads.find(f, text, find_path, {}, opts, context.allocator)
		return err == nil && answer.outcome == .Found
	case 3:
		d, derr := tape.demand_of(scan_paths)
		defer tape.destroy(&d)
		if derr != nil {
			return false
		}
		r, err := reads.scan(f, text, &d, {}, opts, context.allocator)
		tape.destroy(&r)
		return err == nil
	case:
		return deep_read(read - 4, reads, f, text, opts, deep_paths, framing, at)
	}
}

DEEP_CORE_READS :: 4 + DEEP_READS
