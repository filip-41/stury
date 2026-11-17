// `edit set <file> <edits>` records `edits` sets on a document of the file, commits their splice three times and
// prints the best commit's time as `ns` and its GB/s, `check` as a hash of the committed text, and the recording's time
// per edit. A `.csv` or `.tsv` file builds a headed dsv text,
// `.json5` and `.jsonc` build a json text of that spec, and any other suffix a `.Json` text. The edits are spread over
// the file's `String`, `Number` and `Plain` value nodes.
package edit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../../../timing"
import core "../../../../core"
import compose "../../../../core/compose"
import typed "../../../../core/typed"
import write "../../../../core/write"
import dsv "../../../../dsv"
import json "../../../../json"

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
	doc: core.Document
	derr: core.Error
	switch {
	case strings.has_suffix(suffix, ".tsv"):
		doc, derr = core.build(src, dsv.as(.Tsv))
	case strings.has_suffix(suffix, ".csv"):
		doc, derr = core.build(src, dsv.as(.Csv))
	case strings.has_suffix(suffix, ".json5"):
		doc, derr = core.build(src, json.as(.Json5))
	case strings.has_suffix(suffix, ".jsonc"):
		doc, derr = core.build(src, json.as(.Jsonc))
	case:
		doc, derr = core.build(src, json.as(.Json))
	}
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
