#+build linux, darwin, freebsd, openbsd, netbsd
package tape

import "base:intrinsics"
import "core:c"
import "core:sys/posix"

// OS virtual memory reservation for large `Document.nodes` buffers on Unix platforms.
//
// `nodes_reserve` reserves a contiguous virtual address range (`MAP_PRIVATE | MAP_ANON`, plus Linux `MAP_NORESERVE`)
// so `Builder` can grow its node buffer in place with zero copying, then `nodes_trim_tail` unmaps the unused
// page-aligned tail and `nodes_unmap` releases the kept pages when `destroy_document` runs.

// Linux `MAP_NORESERVE` bit (`1 << 14`), matching `core:sys/linux.Map_Flags_Bits.NORESERVE` on amd64, arm64, riscv64.
@(private = "file")
LINUX_MAP_NORESERVE :: c.int(0x4000)

@(private = "file")
cached_page_size: int

@(private = "file")
nodes_page_size :: proc "contextless" () -> int {
	if p := intrinsics.atomic_load_explicit(&cached_page_size, .Relaxed); p > 0 {
		return p
	}
	p := int(posix.sysconf(._PAGESIZE))
	if p < 4096 || (p & (p - 1)) != 0 {
		p = 4096
	}
	intrinsics.atomic_store_explicit(&cached_page_size, p, .Relaxed)
	return p
}

@(private = "file")
align_up :: #force_inline proc "contextless" (n, page: int) -> (aligned: int, ok: bool) {
	mask := page - 1
	if n < 0 || n > max(int) - mask {
		return 0, false
	}
	return (n + mask) &~ mask, true
}

// Page-aligned byte length backing `n` nodes, or 0 for non-positive / overflowing counts.
nodes_mapped_bytes :: proc "contextless" (n: int) -> int {
	if n <= 0 || n > max(int) / size_of(Node) {
		return 0
	}
	aligned, ok := align_up(n * size_of(Node), nodes_page_size())
	return aligned if ok else 0
}

// Reserves virtual address space for up to `max_nodes` nodes via anonymous `mmap`.
nodes_reserve :: proc "contextless" (max_nodes: int) -> (buf: []Node, reserved_bytes: int, ok: bool) {
	when size_of(uintptr) < 8 {
		_ = max_nodes
		return nil, 0, false
	} else {
		bytes := nodes_mapped_bytes(max_nodes)
		if bytes <= 0 {
			return nil, 0, false
		}
		flags := posix.Map_Flags{.PRIVATE, .ANONYMOUS}
		when ODIN_OS == .Linux {
			flags = transmute(posix.Map_Flags)(transmute(c.int)flags | LINUX_MAP_NORESERVE)
		}
		addr := posix.mmap(nil, c.size_t(bytes), {.READ, .WRITE}, flags)
		if addr == nil || addr == posix.MAP_FAILED {
			return nil, 0, false
		}
		return ([^]Node)(addr)[:max_nodes], bytes, true
	}
}

// Ensures at least `need_nodes` of a reserved `buf` are readable and writable. On Unix the mapping is already
// `PROT_READ | PROT_WRITE` (demand-paged by the kernel), so this only validates bounds and updates `committed_bytes`
// with zero syscalls.
nodes_commit :: proc "contextless" (buf: []Node, committed_bytes: ^int, need_nodes: int) -> bool {
	if need_nodes <= 0 {
		return true
	}
	if raw_data(buf) == nil || need_nodes > len(buf) {
		return false
	}
	max_bytes := nodes_mapped_bytes(len(buf))
	need_bytes := nodes_mapped_bytes(need_nodes)
	if need_bytes == 0 || need_bytes > max_bytes {
		return false
	}
	if committed_bytes != nil && need_bytes > committed_bytes^ {
		committed_bytes^ = need_bytes
	}
	return true
}

// Unmaps the page-aligned unused tail past `used_nodes` from a `reserved_bytes` mapping, returning `buf[:used_nodes]`.
// When `used_nodes <= 0`, unmaps all `reserved_bytes` and returns `nil`.
nodes_trim_tail :: proc "contextless" (buf: []Node, used_nodes, reserved_bytes: int, committed_bytes := 0) -> []Node {
	_ = committed_bytes
	p := raw_data(buf)
	if p == nil || reserved_bytes <= 0 {
		return nil
	}
	if used_nodes <= 0 {
		_ = posix.munmap(p, c.size_t(reserved_bytes))
		return nil
	}
	used := min(used_nodes, len(buf))
	aligned_used := nodes_mapped_bytes(used)
	if aligned_used > 0 && aligned_used < reserved_bytes {
		base := ([^]u8)(p)
		_ = posix.munmap(base[aligned_used:], c.size_t(reserved_bytes - aligned_used))
	}
	return buf[:used]
}

// Releases a tail-trimmed mapped node slice via `munmap`.
nodes_unmap :: proc "contextless" (nodes: []Node) {
	p := raw_data(nodes)
	if p == nil || len(nodes) == 0 {
		return
	}
	if size := nodes_mapped_bytes(len(nodes)); size > 0 {
		_ = posix.munmap(p, c.size_t(size))
	}
}
