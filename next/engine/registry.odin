package engine

import "stury:cbor"
import "stury:dsv"
import "stury:html"
import "stury:json"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

// Format registry: single source of truth mapping between `Format_Id`, `Spec`, `tape.Format_Id`,
// runtime `^tape.Format` handles, `^tape.Reads` dispatch tables, names/aliases, and extensions.

Family :: enum u8 {
	Json,
	Toml,
	Xml,
	Dsv,
	Cbor,
	Yaml,
	Html,
	Msgpack,
}

Format_Id :: enum u8 {
	Json,
	Jsonc,
	Json5,
	Toml_1_0,
	Toml_1_1,
	Xml,
	Csv,
	Tsv,
	Plain,
	Cbor,
	Cbor_Preferred,
	Cbor_Deterministic,
	Cbor_Length_First,
	Yaml,
	Yaml_Merge,
	Html,
	Html_Fragment,
	Msgpack,
	Msgpack_Compact,
}

Spec :: union {
	json.Spec,
	toml.Spec,
	xml.Spec,
	dsv.Spec,
	cbor.Spec,
	yaml.Spec,
	html.Spec,
	msgpack.Spec,
}

Framing :: enum u8 {
	Single,
	Lines,
	Seq,
	Elements,
	Members,
	Concatenated,
}

Format_Entry :: struct {
	id:              Format_Id,
	family:          Family,
	spec:            Spec,
	tape_id:         tape.Format_Id,
	name:            string,
	title:           string,
	aliases:         []string,
	extensions:      []string,
	default_framing: Framing,
	supports_scan:   bool,
	binary:          bool,
	tabular:         bool,
	groups_dups:     bool,
	format:          ^tape.Format,
	reads:           ^tape.Reads,
}

@(private)
Format_Meta :: struct {
	id:              Format_Id,
	family:          Family,
	spec:            Spec,
	tape_id:         tape.Format_Id,
	name:            string,
	title:           string,
	aliases:         []string,
	extensions:      []string,
	default_framing: Framing,
	supports_scan:   bool,
	binary:          bool,
	tabular:         bool,
	groups_dups:     bool,
}

@(private = "file", rodata)
JSON_ALIASES := [?]string{"ndjson", "jsonl", "ldjson", "jsonlines", "jsonseq", "json-seq", "rfc7464"}
@(private = "file", rodata)
JSON_EXTS := [?]string{"json", "ndjson", "jsonl", "ldjson", "jsonlines", "jsonseq"}
@(private = "file", rodata)
JSONC_ALIASES := [?]string{"json-c", "json_c", "json+comments"}
@(private = "file", rodata)
JSONC_EXTS := [?]string{"jsonc"}
@(private = "file", rodata)
JSON5_ALIASES := [?]string{"json-5", "json_5"}
@(private = "file", rodata)
JSON5_EXTS := [?]string{"json5"}
@(private = "file", rodata)
TOML10_ALIASES := [?]string{"toml1.0", "toml-1.0", "toml1_0", "toml:1.0", "toml_1_0"}
@(private = "file", rodata)
TOML10_EXTS := [?]string{"toml"}
@(private = "file", rodata)
TOML11_ALIASES := [?]string{"toml1.1", "toml-1.1", "toml1_1", "toml:1.1", "toml_1_1"}
@(private = "file", rodata)
XML_ALIASES := [?]string{"xml1.0", "xml-1.0"}
@(private = "file", rodata)
XML_EXTS := [?]string{"xml", "xhtml", "svg", "rss", "atom", "plist"}
@(private = "file", rodata)
CSV_EXTS := [?]string{"csv"}
@(private = "file", rodata)
TSV_EXTS := [?]string{"tsv", "tab"}
@(private = "file", rodata)
PLAIN_ALIASES := [?]string{"dsv", "dsv:plain", "dsv_plain"}
@(private = "file", rodata)
PLAIN_EXTS := [?]string{"dsv"}
@(private = "file", rodata)
CBOR_EXTS := [?]string{"cbor"}
@(private = "file", rodata)
CBOR_PREF_ALIASES := [?]string{"cbor:preferred", "cbor-preferred", "cbor_preferred"}
@(private = "file", rodata)
CBOR_DET_ALIASES := [?]string{"cbor:deterministic", "cbor-deterministic", "cbor_deterministic"}
@(private = "file", rodata)
CBOR_LF_ALIASES := [?]string{"cbor:length_first", "cbor:length-first", "cbor-length-first", "cbor_length_first"}
@(private = "file", rodata)
YAML_ALIASES := [?]string{"yml", "yaml:1.2", "yaml1.2", "yaml-1.2", "yaml_1_2"}
@(private = "file", rodata)
YAML_EXTS := [?]string{"yaml", "yml"}
@(private = "file", rodata)
YAML_MERGE_ALIASES := [?]string{"yaml-merge", "yaml_merge"}
@(private = "file", rodata)
HTML_ALIASES := [?]string{"htm", "html5"}
@(private = "file", rodata)
HTML_EXTS := [?]string{"html", "htm"}
@(private = "file", rodata)
HTML_FRAG_ALIASES := [?]string{"html-fragment", "html_fragment"}
@(private = "file", rodata)
MSGPACK_ALIASES := [?]string{"mpk", "msgpk"}
@(private = "file", rodata)
MSGPACK_EXTS := [?]string{"msgpack", "mpk"}
@(private = "file", rodata)
MSGPACK_COMPACT_ALIASES := [?]string{"msgpack-compact", "msgpack_compact", "mpk:compact"}

@(private)
FORMAT_META := [Format_Id]Format_Meta {
	.Json               = {.Json, .Json, json.Spec.Json, tape.FORMAT_ID_JSON + 0, "json", "JSON", JSON_ALIASES[:], JSON_EXTS[:], .Single, true, false, false, false},
	.Jsonc              = {.Jsonc, .Json, json.Spec.Jsonc, tape.FORMAT_ID_JSON + 1, "jsonc", "JSON with comments", JSONC_ALIASES[:], JSONC_EXTS[:], .Single, true, false, false, false},
	.Json5              = {.Json5, .Json, json.Spec.Json5, tape.FORMAT_ID_JSON + 2, "json5", "JSON5", JSON5_ALIASES[:], JSON5_EXTS[:], .Single, true, false, false, false},
	.Toml_1_0           = {.Toml_1_0, .Toml, toml.Spec.Toml_1_0, tape.FORMAT_ID_TOML + 0, "toml", "TOML 1.0", TOML10_ALIASES[:], TOML10_EXTS[:], .Single, false, false, false, false},
	.Toml_1_1           = {.Toml_1_1, .Toml, toml.Spec.Toml_1_1, tape.FORMAT_ID_TOML + 1, "toml1.1", "TOML 1.1", TOML11_ALIASES[:], nil, .Single, false, false, false, false},
	.Xml                = {.Xml, .Xml, xml.Spec.Xml, tape.FORMAT_ID_XML, "xml", "XML", XML_ALIASES[:], XML_EXTS[:], .Single, true, false, false, true},
	.Csv                = {.Csv, .Dsv, dsv.Spec.Csv, tape.FORMAT_ID_DSV + 0, "csv", "CSV", nil, CSV_EXTS[:], .Lines, true, false, true, false},
	.Tsv                = {.Tsv, .Dsv, dsv.Spec.Tsv, tape.FORMAT_ID_DSV + 1, "tsv", "TSV", nil, TSV_EXTS[:], .Lines, true, false, true, false},
	.Plain              = {.Plain, .Dsv, dsv.Spec.Plain, tape.FORMAT_ID_DSV + 2, "plain", "DSV (plain)", PLAIN_ALIASES[:], PLAIN_EXTS[:], .Lines, true, false, true, false},
	.Cbor               = {.Cbor, .Cbor, cbor.Spec.Cbor, tape.FORMAT_ID_CBOR + 0, "cbor", "CBOR", nil, CBOR_EXTS[:], .Concatenated, true, true, false, false},
	.Cbor_Preferred     = {.Cbor_Preferred, .Cbor, cbor.Spec.Preferred, tape.FORMAT_ID_CBOR + 1, "cbor:preferred", "CBOR (preferred)", CBOR_PREF_ALIASES[:], nil, .Concatenated, true, true, false, false},
	.Cbor_Deterministic = {.Cbor_Deterministic, .Cbor, cbor.Spec.Deterministic, tape.FORMAT_ID_CBOR + 2, "cbor:deterministic", "CBOR (deterministic)", CBOR_DET_ALIASES[:], nil, .Concatenated, true, true, false, false},
	.Cbor_Length_First  = {.Cbor_Length_First, .Cbor, cbor.Spec.Length_First, tape.FORMAT_ID_CBOR + 3, "cbor:length_first", "CBOR (length-first)", CBOR_LF_ALIASES[:], nil, .Concatenated, true, true, false, false},
	.Yaml               = {.Yaml, .Yaml, yaml.Spec.Yaml_1_2, tape.FORMAT_ID_YAML + 0, "yaml", "YAML 1.2", YAML_ALIASES[:], YAML_EXTS[:], .Single, true, false, false, false},
	.Yaml_Merge         = {.Yaml_Merge, .Yaml, yaml.Spec.Yaml_Merge, tape.FORMAT_ID_YAML + 1, "yaml:merge", "YAML 1.2 (merge)", YAML_MERGE_ALIASES[:], nil, .Single, true, false, false, false},
	.Html               = {.Html, .Html, html.Spec.Html, tape.FORMAT_ID_HTML + 0, "html", "HTML5", HTML_ALIASES[:], HTML_EXTS[:], .Single, false, false, false, true},
	.Html_Fragment      = {.Html_Fragment, .Html, html.Spec.Fragment, tape.FORMAT_ID_HTML + 1, "html:fragment", "HTML5 (fragment)", HTML_FRAG_ALIASES[:], nil, .Single, false, false, false, true},
	.Msgpack            = {.Msgpack, .Msgpack, msgpack.Spec.Msgpack, tape.FORMAT_ID_MSGPACK + 0, "msgpack", "MessagePack", MSGPACK_ALIASES[:], MSGPACK_EXTS[:], .Concatenated, true, true, false, false},
	.Msgpack_Compact    = {.Msgpack_Compact, .Msgpack, msgpack.Spec.Compact, tape.FORMAT_ID_MSGPACK + 1, "msgpack:compact", "MessagePack (compact)", MSGPACK_COMPACT_ALIASES[:], nil, .Concatenated, true, true, false, false},
}

to_tape_framing :: proc "contextless" (f: Framing) -> (tf: tape.Framing, framed: bool) {
	switch f {
	case .Single:       return {}, false
	case .Lines:        return .Lines, true
	case .Seq:          return .Seq, true
	case .Elements:     return .Elements, true
	case .Members:      return .Members, true
	case .Concatenated: return .Concatenated, true
	}
	return {}, false
}

id_of_spec :: proc "contextless" (spec: Spec) -> (id: Format_Id, ok: bool) {
	if spec == nil {
		return {}, false
	}
	for m in FORMAT_META {
		if m.spec == spec {
			return m.id, true
		}
	}
	return {}, false
}

spec_of_id :: proc "contextless" (id: Format_Id) -> Spec {
	return FORMAT_META[id].spec
}

format_handle_of_id :: proc "contextless" (id: Format_Id) -> ^tape.Format {
	switch id {
	case .Json:               return json.as(.Json)
	case .Jsonc:              return json.as(.Jsonc)
	case .Json5:              return json.as(.Json5)
	case .Toml_1_0:           return toml.as(.Toml_1_0)
	case .Toml_1_1:           return toml.as(.Toml_1_1)
	case .Xml:                return xml.as(.Xml)
	case .Csv:                return dsv.as(.Csv)
	case .Tsv:                return dsv.as(.Tsv)
	case .Plain:              return dsv.as(.Plain)
	case .Cbor:               return cbor.as(.Cbor)
	case .Cbor_Preferred:     return cbor.as(.Preferred)
	case .Cbor_Deterministic: return cbor.as(.Deterministic)
	case .Cbor_Length_First:  return cbor.as(.Length_First)
	case .Yaml:               return yaml.as(.Yaml_1_2)
	case .Yaml_Merge:         return yaml.as(.Yaml_Merge)
	case .Html:               return html.as(.Html)
	case .Html_Fragment:      return html.as(.Fragment)
	case .Msgpack:            return msgpack.as(.Msgpack)
	case .Msgpack_Compact:    return msgpack.as(.Compact)
	}
	return nil
}

reads_of_id :: proc "contextless" (id: Format_Id) -> ^tape.Reads {
	switch id {
	case .Json:               return json.reads(.Json)
	case .Jsonc:              return json.reads(.Jsonc)
	case .Json5:              return json.reads(.Json5)
	case .Toml_1_0:           return toml.reads(.Toml_1_0)
	case .Toml_1_1:           return toml.reads(.Toml_1_1)
	case .Xml:                return xml.reads(.Xml)
	case .Csv:                return dsv.reads(.Csv)
	case .Tsv:                return dsv.reads(.Tsv)
	case .Plain:              return dsv.reads(.Plain)
	case .Cbor:               return cbor.reads(.Cbor)
	case .Cbor_Preferred:     return cbor.reads(.Preferred)
	case .Cbor_Deterministic: return cbor.reads(.Deterministic)
	case .Cbor_Length_First:  return cbor.reads(.Length_First)
	case .Yaml:               return yaml.reads(.Yaml_1_2)
	case .Yaml_Merge:         return yaml.reads(.Yaml_Merge)
	case .Html:               return html.reads(.Html)
	case .Html_Fragment:      return html.reads(.Fragment)
	case .Msgpack:            return msgpack.reads(.Msgpack)
	case .Msgpack_Compact:    return msgpack.reads(.Compact)
	}
	return nil
}

format_of :: proc "contextless" (spec: Spec) -> ^tape.Format {
	id, ok := id_of_spec(spec)
	return format_handle_of_id(id) if ok else nil
}

reads_of :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	id, ok := id_of_spec(spec)
	return reads_of_id(id) if ok else nil
}

entry_of_id :: proc "contextless" (id: Format_Id) -> (entry: Format_Entry, ok: bool) {
	if int(id) >= len(FORMAT_META) {
		return {}, false
	}
	m := FORMAT_META[id]
	return {
		id              = m.id,
		family          = m.family,
		spec            = m.spec,
		tape_id         = m.tape_id,
		name            = m.name,
		title           = m.title,
		aliases         = m.aliases,
		extensions      = m.extensions,
		default_framing = m.default_framing,
		supports_scan   = m.supports_scan,
		binary          = m.binary,
		tabular         = m.tabular,
		groups_dups     = m.groups_dups,
		format          = format_handle_of_id(id),
		reads           = reads_of_id(id),
	}, true
}

entry_of_spec :: proc "contextless" (spec: Spec) -> (entry: Format_Entry, ok: bool) {
	id, found := id_of_spec(spec)
	if !found {
		return {}, false
	}
	return entry_of_id(id)
}

entry_of_tape_id :: proc "contextless" (tid: tape.Format_Id) -> (entry: Format_Entry, ok: bool) {
	for m in FORMAT_META {
		if m.tape_id == tid {
			return entry_of_id(m.id)
		}
	}
	return {}, false
}

entry_of_format :: proc "contextless" (fmt_handle: ^tape.Format) -> (entry: Format_Entry, ok: bool) {
	if fmt_handle == nil {
		return {}, false
	}
	return entry_of_tape_id(fmt_handle.id)
}

entry_of :: proc {
	entry_of_id,
	entry_of_spec,
	entry_of_tape_id,
	entry_of_format,
}

spec_of :: proc "contextless" (fmt_handle: ^tape.Format) -> (spec: Spec, ok: bool) {
	e, found := entry_of_format(fmt_handle)
	return e.spec if found else nil, found
}

supports_scan :: proc "contextless" (spec: Spec) -> bool {
	e, ok := entry_of_spec(spec)
	return ok && e.supports_scan
}

@(private)
ascii_eq_fold :: proc "contextless" (a, b: string) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' { ca += 'a' - 'A' }
		if cb >= 'A' && cb <= 'Z' { cb += 'a' - 'A' }
		if ca != cb {
			return false
		}
	}
	return true
}

@(private)
json_framing_for_tag :: proc "contextless" (tag: string, base: Framing) -> Framing {
	switch {
	case ascii_eq_fold(tag, "ndjson"), ascii_eq_fold(tag, "jsonl"), ascii_eq_fold(tag, "ldjson"), ascii_eq_fold(tag, "jsonlines"):
		return .Lines
	case ascii_eq_fold(tag, "jsonseq"), ascii_eq_fold(tag, "json-seq"), ascii_eq_fold(tag, "rfc7464"):
		return .Seq
	}
	return base
}

format_by_name :: proc "contextless" (name: string) -> (entry: Format_Entry, ok: bool) {
	if len(name) == 0 {
		return {}, false
	}
	for m in FORMAT_META {
		if ascii_eq_fold(name, m.name) {
			return entry_of_id(m.id)
		}
		for alias in m.aliases {
			if ascii_eq_fold(name, alias) {
				return entry_of_id(m.id)
			}
		}
	}
	return {}, false
}

format_and_framing_by_name :: proc "contextless" (name: string) -> (entry: Format_Entry, framing: Framing, ok: bool) {
	entry, ok = format_by_name(name)
	if !ok {
		return {}, .Single, false
	}
	framing = json_framing_for_tag(name, entry.default_framing) if entry.id == .Json else entry.default_framing
	return entry, framing, true
}
