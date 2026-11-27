#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !windows
package tape

// Fallback for targets without OS virtual memory reservation (WebAssembly, freestanding): zero OS imports,
// `nodes_reserve` reports unavailable so callers fall back cleanly to `runtime.Allocator`.

nodes_mapped_bytes :: proc "contextless" (n: int) -> int {
	_ = n
	return 0
}

nodes_reserve :: proc "contextless" (max_nodes: int) -> (buf: []Node, reserved_bytes: int, ok: bool) {
	_ = max_nodes
	return nil, 0, false
}

nodes_commit :: proc "contextless" (buf: []Node, committed_bytes: ^int, need_nodes: int) -> bool {
	_ = buf
	_ = committed_bytes
	return need_nodes <= 0
}

nodes_trim_tail :: proc "contextless" (buf: []Node, used_nodes, reserved_bytes: int, committed_bytes := 0) -> []Node {
	_ = reserved_bytes
	_ = committed_bytes
	if used_nodes <= 0 {
		return nil
	}
	return buf[:min(used_nodes, len(buf))]
}

nodes_unmap :: proc "contextless" (nodes: []Node) {
	_ = nodes
}
