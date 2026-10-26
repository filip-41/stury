#+build !windows
package main

// The command line's calls into the system on POSIX. platform_windows.odin has Windows's.

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sys/posix"

@(private = "file")
STACK_GUARD :: 1 << 20
@(private = "file")
stack_guard: [2]uintptr
@(private = "file")
fault_stack: [1 << 16]byte

// `body` on the interpreter's stack. If that cannot be had, the run ends as one that is out of memory, since a
// filter on this thread's stack would have no guard against its recursion.
run_deep :: proc(run: ^Run, ins: ^Inputs, body: proc(run: ^Run, ins: ^Inputs)) {
	// Process-wide, so it covers every thread and the fallbacks below. The interpreter's thread adds its alternate
	// stack.
	act := posix.sigaction_t{sa_sigaction = fault, sa_flags = {.ONSTACK, .SIGINFO, .RESETHAND}}
	posix.sigaction(.SIGSEGV, &act, nil)
	posix.sigaction(.SIGBUS, &act, nil)
	MAP_NORESERVE :: 0x4000 when ODIN_OS == .Linux else 0 // a reservation, not memory set aside
	flags := transmute(posix.Map_Flags)i32(posix.MAP_PRIVATE | posix.MAP_ANONYMOUS | MAP_NORESERVE)
	base := posix.mmap(nil, DEEP_STACK, {.READ, .WRITE}, flags, -1, 0)
	if base == posix.MAP_FAILED {
		out_of_memory()
	}
	if posix.mprotect(base, STACK_GUARD, {}) != .OK {
		posix.munmap(base, DEEP_STACK)
		out_of_memory()
	}
	stack_guard = {uintptr(base), uintptr(base) + STACK_GUARD}
	attr: posix.pthread_attr_t
	posix.pthread_attr_init(&attr)
	posix.pthread_attr_setstack(&attr, ([^]byte)(base)[STACK_GUARD:], DEEP_STACK - STACK_GUARD)
	job := Deep_Job{run, ins, body, context}
	t: posix.pthread_t
	started := posix.pthread_create(&t, &attr, proc "c" (arg: rawptr) -> rawptr {
		job := (^Deep_Job)(arg)
		context = job.ctx
		// The fault handler runs on a stack of its own, as this one is spent when it is called.
		alt := posix.stack_t{ss_sp = &fault_stack, ss_size = len(fault_stack)}
		posix.sigaltstack(&alt, nil)
		job.body(job.run, job.ins)
		return nil
	}, &job)
	if started != .NONE {
		posix.munmap(base, DEEP_STACK)
		out_of_memory()
	}
	posix.pthread_join(t, nil)
}

// The line a fault in the stack's guard prints (and jq's, for memory run out), then exit 2: the stack was not had.
@(private = "file")
out_of_memory :: proc() -> ! {
	fmt.eprintln("stury: error: cannot allocate memory")
	os.exit(EXIT_USAGE)
}

// A fault in the guard below the interpreter's stack: jq's message for memory run out, then abort as jq does.
// A SIGBUS with an input mapped is that file shrinking under its mapping: say so and exit 2, as for a failed
// read. Only write(2) and _exit(2) run here. Any other fault is left to the default action, which the access
// meets again once this returns.
@(private = "file")
fault :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, _: rawptr) {
	say :: proc "contextless" (s: string) {
		posix.write(posix.STDERR_FILENO, raw_data(s), len(s))
	}
	if at := uintptr(info.si_addr); stack_guard[0] <= at && at < stack_guard[1] {
		say("stury: error: cannot allocate memory\n")
		posix.abort()
	}
	if sig == .SIGBUS && mapped_input_name != "" {
		say("stury: error: ")
		say(mapped_input_name)
		say(": input file shrank while reading\n")
		posix._exit(2)
	}
}

// All of `p` written to stdout, as stdio's fwrite does for jq: a short write goes on, EINTR is retried, and EAGAIN
// (a nonblocking descriptor that is full) waits until it can be written to. Any other error is returned.
write_stdout :: proc(p: []byte) -> os.Error {
	p := p
	for len(p) > 0 {
		n := posix.write(posix.STDOUT_FILENO, raw_data(p), uint(min(len(p), 1 << 30)))
		if n > 0 {
			p = p[n:]
			continue
		}
		e := posix.errno() if n < 0 else posix.Errno.EIO
		#partial switch e {
		case .EINTR:
		case .EAGAIN:
			fd := posix.pollfd{fd = posix.STDOUT_FILENO, events = {.OUT}}
			posix.poll(&fd, 1, -1)
		case:
			return os.Platform_Error(i32(e))
		}
	}
	return nil
}

is_terminal :: proc(f: ^os.File) -> bool {
	return bool(posix.isatty(posix.FD(os.fd(f))))
}

// Colour needs nothing set up here.
enable_color :: proc() {}

// Gives the file `f` the owner and group of the file at `path`, or only the group where the owner cannot be given
// (not the superuser), or neither. A best effort: the temporary file `fmt --in-place` writes is the user's own.
keep_owner :: proc(f: ^os.File, path: string) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return
	}
	fd := posix.FD(os.fd(f))
	if posix.fchown(fd, st.st_uid, st.st_gid) != .OK {
		posix.fchown(fd, posix.uid_t(max(u32)), st.st_gid)
	}
}

is_regular_file :: proc(f: ^os.File) -> bool {
	st: posix.stat_t
	return posix.fstat(posix.FD(os.fd(f)), &st) == .OK && posix.S_ISREG(st.st_mode)
}

// os.read, but a failed read(2) as its errno (EISDIR), which jq prints: os.read tells it only as Unknown.
read_some :: proc(f: ^os.File, p: []byte) -> (int, os.Error) {
	n, err := os.read(f, p)
	if err == io.Error.Unknown {
		err = os.Platform_Error(i32(posix.errno()))
	}
	return n, err
}

// What C's strerror says of an errno.
platform_error_text :: proc(e: os.Platform_Error) -> string {
	return string(posix.strerror(posix.Errno(i32(e))))
}

// Regular file `f`, from its current offset to its end, mapped copy-on-write, as its readers may write into it
// (`stand_in`). It returns false if it does not map (nothing left, a file system that maps none), and it is to be
// read. Stdin is mapped too, and left at its end as a read would leave it. The mapping starts at the page before the
// offset (`unmap_file` finds it again).
map_file :: proc(f: ^os.File) -> ([]byte, bool) {
	if !is_regular_file(f) {
		return nil, false
	}
	fd := posix.FD(os.fd(f))
	size, err := os.file_size(f)
	at := posix.lseek(fd, 0, .CUR)
	if err != nil || at < 0 || i64(int(size)) != size || size <= i64(at) {
		return nil, false
	}
	page := i64(posix.sysconf(._PAGESIZE))
	lo := i64(at) / page * page
	p := posix.mmap(nil, uint(size - lo), {.READ, .WRITE}, {.PRIVATE}, fd, posix.off_t(lo))
	if p == posix.MAP_FAILED {
		return nil, false
	}
	posix.lseek(fd, posix.off_t(size), .SET)
	return ([^]byte)(p)[i64(at) - lo:size - lo], true
}

unmap_file :: proc(data: []byte) {
	page := uintptr(posix.sysconf(._PAGESIZE))
	base := uintptr(raw_data(data)) / page * page
	posix.munmap(rawptr(base), uint(len(data)) + uint(uintptr(raw_data(data)) - base))
}
