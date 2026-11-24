package hook

import "base:intrinsics"

// The distance between the stack probe's reads, a guard page at the least: a page of 16 KiB on arm64 macOS, else 4 KiB.
STACK_PAGE :: 16 * 1024 when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 else 4 * 1024

// Reads the `BYTES` below the stack pointer a page at a time from the top, so that on a thread with less stack a read
// faults on its guard page before its frames are written past it. WebAssembly's shadow stack has no guard page and
// traps at its base, which the frame alone reaches, so the probe reads nothing there.
@(no_sanitize_address)
probe_stack :: #force_no_inline proc "contextless" ($BYTES: uintptr) {
	#assert(BYTES % STACK_PAGE == 0)
	when ODIN_ARCH != .wasm32 && ODIN_ARCH != .wasm64p32 {
		sp := uintptr(intrinsics.stack_pointer())
		for k := uintptr(STACK_PAGE); k <= BYTES; k += STACK_PAGE {
			_ = intrinsics.volatile_load((^u8)(sp - k))
		}
	}
}
