// `edit set <file> <edits>` records `edits` sets on a document of the file, commits their splice three times and
// prints the best commit's time as `ns` and its GB/s, `check` as a hash of the committed text, and the recording's time
// per edit. A file is built as the format its suffix names (`formats.of_path`), a `.csv` or `.tsv` file as a headed dsv
// text, and any suffix none names as a `.Json` text. The edits are spread over
// the file's `String`, `Number` and `Plain` value nodes, the empty ones of an HTML text left out.
package edit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../../../formats"
import "../../../timing"
import core "../../../../core"
import compose "../../../../core/compose"
import typed "../../../../core/typed"
import write "../../../../core/write"

main :: proc() {
	if len(os.args) != 4 || os.args[1] != "set" {
		fmt.eprintln("usage: edit set <file> <edits>")
		os.exit(2)
	}
	src, err := os.read_entire_file_from_path(os.args[2], context.allocator)
	if err != nil {
		fmt.eprintln("read:", err)
		os.exit(1)
	}
	defer delete(src)
	want := 0
	for c in os.args[3] {
		want = want * 10 + int(c - '0')
	}
	suffix := os.args[2]
	dsv_text := strings.has_suffix(suffix, ".csv") || strings.has_suffix(suffix, ".tsv")
	kind := formats.of_path(suffix)
	doc, derr := core.build(src, formats.handle(kind))
	defer core.destroy(&doc)
	if derr != nil {
		fmt.eprintln("build:", derr)
		os.exit(1)
	}
	nodes := make([dynamic]core.Node_Index, 0, 1024)
	defer delete(nodes)
	for n, i in doc.nodes {
		if n.role != .Value || (n.kind != .String && n.kind != .Number && n.kind != .Plain) {
			continue
		}
		// An empty HTML element, a void one among them, holds no content to set.
		if kind == .Html && n.n == 0 {
			continue
		}
		append(&nodes, core.Node_Index(i))
	}
	n := min(want, len(nodes))
	text := "0"
	if dsv_text {
		text = "x"
	}

	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	start := time.tick_now()
	for k in 0 ..< n {
		// Spreads the edits over the whole file, so their order in the log is not their order in the source.
		node := nodes[k * len(nodes) / max(n, 1)]
		if e := write.set_node(&list, node, typed.Raw(text)); e != nil {
			fmt.eprintln("set:", e)
			os.exit(1)
		}
	}
	record := time.tick_since(start)
	best := time.Duration(max(i64))
	out: []u8
	for _ in 0 ..< 3 {
		start = time.tick_now()
		next, _, cerr := compose.commit(&list)
		d := time.tick_since(start)
		if cerr != nil {
			fmt.eprintln("commit:", cerr)
			os.exit(1)
		}
		if out != nil {
			delete(out)
		}
		out = next
		best = min(best, d)
	}
	fmt.printfln("gb_per_s=%.4f ns=%d check=%d record_ns_per_edit=%.1f", f64(len(src)) / f64(max(best, 1)), i64(best),
		timing.fnv_bytes(timing.CHECK_OFFSET, out), f64(record) / f64(max(n, 1)))
	delete(out)
}
