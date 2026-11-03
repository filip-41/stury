package document_oracle

import "core:fmt"
import "core:strings"
import json "stury:json"

OPTS :: [?]json.Document_Opts {
	{},
	{pretty = true, indent = 2},
	{pretty = true, indent = 4},
	{pretty = true, indent = 0},
	{ascii_only = true},
	{escape_html = true},
	{sort_keys = true},
	{pretty = true, indent = 2, sort_keys = true},
}

arm :: proc(name: string, src: []u8) {
	jsonc := strings.has_suffix(name, JSONC)
	read := json.Read_Opts{dialect = .Jsonc} if jsonc else json.Read_Opts{}
	doc, err := json.build(src, read)
	if err != nil {
		write_text(fmt.tprintf("%s.refused", name), transmute([]u8)string("refused"))
		return
	}
	for opts, i in OPTS {
		text, werr := json.marshal(&doc, opts)
		assert(werr == nil, fmt.tprint(name, werr))
		write_text(fmt.tprintf("%s.%s.json", name, LAYOUTS[i]), text)
		direct, ferr := json.format(src, read, opts)
		assert(ferr == nil, fmt.tprint(name, ferr))
		write_text(fmt.tprintf("%s.%s.format.json", name, LAYOUTS[i]), direct)
	}
}

main :: proc() {
	all_texts(arm)
}
