#+build windows
package tape

import "base:intrinsics"
import win32 "core:sys/windows"

// OS virtual memory reservation for large `Document.nodes` buffers on Windows.
//
// `nodes_reserve` reserves address space with `MEM_RESERVE` / `PAGE_NOACCESS`, `nodes_commit` commits in 2 MiB steps
// with `MEM_COMMIT` / `PAGE_READWRITE`, `nodes_trim_tail` decommits unused committed tail pages (or releases the whole
// reservation when `used_nodes <= 0`), and `nodes_unmap` releases the full region via `MEM_RELEASE`.

@(private = "file")
COMMIT_STEP :: 2 << 20

@(private = "file")
cached_page_size: int

@(private = "file")
nodes_page_size :: proc "contextless" () -> int {
	if p := intrinsics.atomic_load_explicit(&cached_page_size, .Relaxed); p > 0 {
		return p
	}
	info: win32.SYSTEM_INFO
	win32.GetSystemInfo(&info)
	p := int(info.dwPageSize)
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

// Reserves virtual address space for up to `max_nodes` nodes via `VirtualAlloc(..., MEM_RESERVE, PAGE_NOACCESS)`.
nodes_reserve :: proc "contextless" (max_nodes: int) -> (buf: []Node, reserved_bytes: int, ok: bool) {
	when size_of(uintptr) < 8 {
		_ = max_nodes
		return nil, 0, false
	} else {
		bytes := nodes_mapped_bytes(max_nodes)
		if bytes <= 0 {
			return nil, 0, false
		}
		addr := win32.VirtualAlloc(nil, uint(bytes), win32.MEM_RESERVE, win32.PAGE_NOACCESS)
		if addr == nil {
			return nil, 0, false
		}
		return ([^]Node)(addr)[:max_nodes], bytes, true
	}
}

// Commits pages in `buf` through at least `need_nodes` in stepped chunks (`COMMIT_STEP`), falling back to exact
// page-aligned commit if a stepped commit hits the commit limit.
nodes_commit :: proc "contextless" (buf: []Node, committed_bytes: ^int, need_nodes: int) -> bool {
	if need_nodes <= 0 {
		return true
	}
	if raw_data(buf) == nil || committed_bytes == nil || need_nodes > len(buf) {
		return false
	}
	need_bytes := nodes_mapped_bytes(need_nodes)
	max_bytes := nodes_mapped_bytes(len(buf))
	if need_bytes == 0 || need_bytes > max_bytes {
		return false
	}
	cur := committed_bytes^
	if need_bytes <= cur {
		return true
	}
	target := need_bytes
	if max_bytes - cur >= COMMIT_STEP {
		step, ok := align_up(cur + COMMIT_STEP, nodes_page_size())
		if ok && step > target {
			target = min(step, max_bytes)
		}
	} else {
		target = max_bytes
	}
	base := ([^]u8)(raw_data(buf))
	if win32.VirtualAlloc(base[cur:], uint(target - cur), win32.MEM_COMMIT, win32.PAGE_READWRITE) == nil {
		if target == need_bytes {
			return false
		}
		if win32.VirtualAlloc(base[cur:], uint(need_bytes - cur), win32.MEM_COMMIT, win32.PAGE_READWRITE) == nil {
			return false
		}
		target = need_bytes
	}
	committed_bytes^ = target
	return true
}

// Decommits unused committed pages past `used_nodes`, or releases the entire reservation when `used_nodes <= 0`.
nodes_trim_tail :: proc "contextless" (buf: []Node, used_nodes, reserved_bytes: int, committed_bytes := 0) -> []Node {
	p := raw_data(buf)
	if p == nil || reserved_bytes <= 0 {
		return nil
	}
	if used_nodes <= 0 {
		_ = win32.VirtualFree(p, 0, win32.MEM_RELEASE)
		return nil
	}
	used := min(used_nodes, len(buf))
	aligned_used := nodes_mapped_bytes(used)
	decommit_end := committed_bytes if committed_bytes > 0 else reserved_bytes
	if aligned_used > 0 && aligned_used < decommit_end {
		base := ([^]u8)(p)
		_ = win32.VirtualFree(base[aligned_used:], uint(decommit_end - aligned_used), win32.MEM_DECOMMIT)
	}
	return buf[:used]
}

// Releases the virtual memory reservation backing `nodes` via `VirtualFree(..., 0, MEM_RELEASE)`.
nodes_unmap :: proc "contextless" (nodes: []Node) {
	if p := raw_data(nodes); p != nil {
		_ = win32.VirtualFree(p, 0, win32.MEM_RELEASE)
	}
}
