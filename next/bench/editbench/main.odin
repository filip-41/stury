// `editbench <file> <edits>` records `edits` sets on a document of the file, commits their splice three times and
// prints the recording's time per edit and the best commit's time. A `.csv` or `.tsv` file builds a headed dsv text,
// `.json5` and `.jsonc` build a json text of that spec, and any other suffix a `.Json` text. The edits are spread over
// the file's `String`, `Number` and `Plain` value nodes.
package editbench

import "core:fmt"
import "core:os"
import "core:time"
import core "../../core"
import dsv "../../dsv"
import json "../../json"

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: editbench <file> <edits>")
		os.exit(2)
	}
	src, err := os.read_entire_file_from_path(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("read:", err)
		os.exit(1)
	}
	defer delete(src)
	want := 0
	for c in os.args[2] {
		want = want * 10 + int(c - '0')
	}
	suffix := os.args[1]
	dsv_text := has_suffix(suffix, ".csv") || has_suffix(suffix, ".tsv")
	doc: core.Document
	derr: core.Document_Error
	switch {
	case has_suffix(suffix, ".tsv"):
		doc, derr = dsv.build(src, .Tsv)
	case has_suffix(suffix, ".csv"):
		doc, derr = dsv.build(src, .Csv)
	case has_suffix(suffix, ".json5"):
		doc, derr = json.build(src, .Json5)
	case has_suffix(suffix, ".jsonc"):
		doc, derr = json.build(src, .Jsonc)
	case:
		doc, derr = json.build(src, .Json)
	}
	defer core.destroy(&doc)
	if derr.kind != .None {
		fmt.eprintln("build:", derr)
		os.exit(1)
	}
	nodes := make([dynamic]u32, 0, 1024)
	defer delete(nodes)
	for n, i in doc.nodes {
		if n.role != .Value || (n.kind != .String && n.kind != .Number && n.kind != .Plain) {
			continue
		}
		append(&nodes, u32(i))
	}
	n := min(want, len(nodes))
	text := transmute([]u8)string("0")
	if dsv_text {
		text = transmute([]u8)string("x")
	}

	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	start := time.tick_now()
	for k in 0 ..< n {
		// Spreads the edits over the whole file, so their order in the log is not their order in the source.
		node := nodes[k * len(nodes) / max(n, 1)]
		if e := core.set(&list, node, text); e.kind != .None {
			fmt.eprintln("set:", e)
			os.exit(1)
		}
	}
	record := time.tick_since(start)
	best := time.Duration(max(i64))
	out: []u8
	for _ in 0 ..< 3 {
		start = time.tick_now()
		next, _, cerr := core.commit(&list)
		d := time.tick_since(start)
		if cerr.kind != .None {
			fmt.eprintln("commit:", cerr)
			os.exit(1)
		}
		if out != nil {
			delete(out)
		}
		out = next
		best = min(best, d)
	}
	fmt.printfln("%s edits=%d nodes=%d bytes=%d record_ns_per_edit=%.1f commit_ns=%d commit_gb_per_s=%.3f out=%d",
		suffix[len(suffix) - 4:], n, len(doc.nodes), len(src),
		f64(record) / f64(max(n, 1)), best, f64(len(src)) / f64(max(best, 1)), len(out))
	delete(out)
}

has_suffix :: proc(s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}
