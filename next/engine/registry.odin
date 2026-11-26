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

// Format family identifier across all supported v2 formats.
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

// Canonical format + specification identifier covering every spec in v2.
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

// Specification union across all 8 v2 formats.
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

// How an input stream is framed at engine level (extending `tape.Framing` with `.Single`).
Framing :: enum u8 {
	Single,
	Lines,
	Seq,
	Elements,
	Members,
	Concatenated,
}

// Registry descriptor for a single format specification, bundling static metadata with runtime
// `^tape.Format` and `^tape.Reads` dispatch tables.
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
	.Json = {
		id              = .Json,
		family          = .Json,
		spec            = json.Spec.Json,
		tape_id         = tape.FORMAT_ID_JSON + 0,
		name            = "json",
		title           = "JSON",
		aliases         = JSON_ALIASES[:],
		extensions      = JSON_EXTS[:],
		default_framing = .Single,
		supports_scan   = true,
	},
	.Jsonc = {
		id              = .Jsonc,
		family          = .Json,
		spec            = json.Spec.Jsonc,
		tape_id         = tape.FORMAT_ID_JSON + 1,
		name            = "jsonc",
		title           = "JSON with comments",
		aliases         = JSONC_ALIASES[:],
		extensions      = JSONC_EXTS[:],
		default_framing = .Single,
		supports_scan   = true,
	},
	.Json5 = {
		id              = .Json5,
		family          = .Json,
		spec            = json.Spec.Json5,
		tape_id         = tape.FORMAT_ID_JSON + 2,
		name            = "json5",
		title           = "JSON5",
		aliases         = JSON5_ALIASES[:],
		extensions      = JSON5_EXTS[:],
		default_framing = .Single,
		supports_scan   = true,
	},
	.Toml_1_0 = {
		id              = .Toml_1_0,
		family          = .Toml,
		spec            = toml.Spec.Toml_1_0,
		tape_id         = tape.FORMAT_ID_TOML + 0,
		name            = "toml",
		title           = "TOML 1.0",
		aliases         = TOML10_ALIASES[:],
		extensions      = TOML10_EXTS[:],
		default_framing = .Single,
		supports_scan   = false,
	},
	.Toml_1_1 = {
		id              = .Toml_1_1,
		family          = .Toml,
		spec            = toml.Spec.Toml_1_1,
		tape_id         = tape.FORMAT_ID_TOML + 1,
		name            = "toml1.1",
		title           = "TOML 1.1",
		aliases         = TOML11_ALIASES[:],
		default_framing = .Single,
		supports_scan   = false,
	},
	.Xml = {
		id              = .Xml,
		family          = .Xml,
		spec            = xml.Spec.Xml,
		tape_id         = tape.FORMAT_ID_XML,
		name            = "xml",
		title           = "XML",
		aliases         = XML_ALIASES[:],
		extensions      = XML_EXTS[:],
		default_framing = .Single,
		supports_scan   = true,
		groups_dups     = true,
	},
	.Csv = {
		id              = .Csv,
		family          = .Dsv,
		spec            = dsv.Spec.Csv,
		tape_id         = tape.FORMAT_ID_DSV + 0,
		name            = "csv",
		title           = "CSV",
		extensions      = CSV_EXTS[:],
		default_framing = .Lines,
		supports_scan   = true,
		tabular         = true,
	},
	.Tsv = {
		id              = .Tsv,
		family          = .Dsv,
		spec            = dsv.Spec.Tsv,
		tape_id         = tape.FORMAT_ID_DSV + 1,
		name            = "tsv",
		title           = "TSV",
		extensions      = TSV_EXTS[:],
		default_framing = .Lines,
		supports_scan   = true,
		tabular         = true,
	},
	.Plain = {
		id              = .Plain,
		family          = .Dsv,
		spec            = dsv.Spec.Plain,
		tape_id         = tape.FORMAT_ID_DSV + 2,
		name            = "plain",
		title           = "DSV (plain)",
		aliases         = PLAIN_ALIASES[:],
		extensions      = PLAIN_EXTS[:],
		default_framing = .Lines,
		supports_scan   = true,
		tabular         = true,
	},
	.Cbor = {
		id              = .Cbor,
		family          = .Cbor,
		spec            = cbor.Spec.Cbor,
		tape_id         = tape.FORMAT_ID_CBOR + 0,
		name            = "cbor",
		title           = "CBOR",
		extensions      = CBOR_EXTS[:],
		default_framing = .Concatenated,
		supports_scan   = true,
		binary          = true,
	},
	.Cbor_Preferred = {
		id              = .Cbor_Preferred,
		family          = .Cbor,
		spec            = cbor.Spec.Preferred,
		tape_id         = tape.FORMAT_ID_CBOR + 1,
		name            = "cbor:preferred",
		title           = "CBOR (preferred)",
		aliases         = CBOR_PREF_ALIASES[:],
		default_framing = .Concatenated,
		supports_scan   = true,
		binary          = true,
	},
	.Cbor_Deterministic = {
		id              = .Cbor_Deterministic,
		family          = .Cbor,
		spec            = cbor.Spec.Deterministic,
		tape_id         = tape.FORMAT_ID_CBOR + 2,
		name            = "cbor:deterministic",
		title           = "CBOR (deterministic)",
		aliases         = CBOR_DET_ALIASES[:],
		default_framing = .Concatenated,
		supports_scan   = true,
		binary          = true,
	},
	.Cbor_Length_First = {
		id              = .Cbor_Length_First,
		family          = .Cbor,
		spec            = cbor.Spec.Length_First,
		tape_id         = tape.FORMAT_ID_CBOR + 3,
		name            = "cbor:length_first",
		title           = "CBOR (length-first)",
		aliases         = CBOR_LF_ALIASES[:],
		default_framing = .Concatenated,
		supports_scan   = true,
		binary          = true,
	},
	.Yaml = {
		id              = .Yaml,
		family          = .Yaml,
		spec            = yaml.Spec.Yaml_1_2,
		tape_id         = tape.FORMAT_ID_YAML + 0,
		name            = "yaml",
		title           = "YAML 1.2",
		aliases         = YAML_ALIASES[:],
		extensions      = YAML_EXTS[:],
		default_framing = .Single,
		supports_scan   = true,
	},
	.Yaml_Merge = {
		id              = .Yaml_Merge,
		family          = .Yaml,
		spec            = yaml.Spec.Yaml_Merge,
		tape_id         = tape.FORMAT_ID_YAML + 1,
		name            = "yaml:merge",
		title           = "YAML 1.2 (merge)",
		aliases         = YAML_MERGE_ALIASES[:],
		default_framing = .Single,
		supports_scan   = true,
	},
	.Html = {
		id              = .Html,
		family          = .Html,
		spec            = html.Spec.Html,
		tape_id         = tape.FORMAT_ID_HTML + 0,
		name            = "html",
		title           = "HTML5",
		aliases         = HTML_ALIASES[:],
		extensions      = HTML_EXTS[:],
		default_framing = .Single,
		supports_scan   = false,
		groups_dups     = true,
	},
	.Html_Fragment = {
		id              = .Html_Fragment,
		family          = .Html,
		spec            = html.Spec.Fragment,
		tape_id         = tape.FORMAT_ID_HTML + 1,
		name            = "html:fragment",
		title           = "HTML5 (fragment)",
		aliases         = HTML_FRAG_ALIASES[:],
		default_framing = .Single,
		supports_scan   = false,
		groups_dups     = true,
	},
	.Msgpack = {
		id              = .Msgpack,
		family          = .Msgpack,
		spec            = msgpack.Spec.Msgpack,
		tape_id         = tape.FORMAT_ID_MSGPACK + 0,
		name            = "msgpack",
		title           = "MessagePack",
		aliases         = MSGPACK_ALIASES[:],
		extensions      = MSGPACK_EXTS[:],
		default_framing = .Concatenated,
		supports_scan   = true,
		binary          = true,
	},
	.Msgpack_Compact = {
		id              = .Msgpack_Compact,
		family          = .Msgpack,
		spec            = msgpack.Spec.Compact,
		tape_id         = tape.FORMAT_ID_MSGPACK + 1,
		name            = "msgpack:compact",
		title           = "MessagePack (compact)",
		aliases         = MSGPACK_COMPACT_ALIASES[:],
		default_framing = .Concatenated,
		supports_scan   = true,
		binary          = true,
	},
}

// Converts an engine `Framing` to a `tape.Framing` when framed (`Single` returns false).
to_tape_framing :: proc "contextless" (f: Framing) -> (tf: tape.Framing, framed: bool) {
	switch f {
	case .Single:
		return {}, false
	case .Lines:
		return .Lines, true
	case .Seq:
		return .Seq, true
	case .Elements:
		return .Elements, true
	case .Members:
		return .Members, true
	case .Concatenated:
		return .Concatenated, true
	}
	return {}, false
}

// Converts `Spec` to canonical `Format_Id`.
id_of_spec :: proc "contextless" (spec: Spec) -> (id: Format_Id, ok: bool) {
	switch s in spec {
	case json.Spec:
		switch s {
		case .Json:  return .Json, true
		case .Jsonc: return .Jsonc, true
		case .Json5: return .Json5, true
		}
	case toml.Spec:
		switch s {
		case .Toml_1_0: return .Toml_1_0, true
		case .Toml_1_1: return .Toml_1_1, true
		}
	case xml.Spec:
		if s == .Xml {
			return .Xml, true
		}
	case dsv.Spec:
		switch s {
		case .Csv:   return .Csv, true
		case .Tsv:   return .Tsv, true
		case .Plain: return .Plain, true
		}
	case cbor.Spec:
		switch s {
		case .Cbor:          return .Cbor, true
		case .Preferred:     return .Cbor_Preferred, true
		case .Deterministic: return .Cbor_Deterministic, true
		case .Length_First:  return .Cbor_Length_First, true
		}
	case yaml.Spec:
		switch s {
		case .Yaml_1_2:   return .Yaml, true
		case .Yaml_Merge: return .Yaml_Merge, true
		}
	case html.Spec:
		switch s {
		case .Html:     return .Html, true
		case .Fragment: return .Html_Fragment, true
		}
	case msgpack.Spec:
		switch s {
		case .Msgpack: return .Msgpack, true
		case .Compact: return .Msgpack_Compact, true
		}
	case nil:
	}
	return {}, false
}

// Converts `Format_Id` to `Spec`.
spec_of_id :: proc "contextless" (id: Format_Id) -> Spec {
	return FORMAT_META[id].spec
}

// Returns the runtime `^tape.Format` handle for `id`.
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

// Returns the runtime `^tape.Reads` dispatch table for `id`.
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

// Returns the runtime `^tape.Format` handle for `spec`.
format_of :: proc "contextless" (spec: Spec) -> ^tape.Format {
	id, ok := id_of_spec(spec)
	if !ok {
		return nil
	}
	return format_handle_of_id(id)
}

// Returns the runtime `^tape.Reads` dispatch table for `spec`.
reads_of :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	id, ok := id_of_spec(spec)
	if !ok {
		return nil
	}
	return reads_of_id(id)
}

// Resolves `entry_of` by `Format_Id`.
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

// Resolves `entry_of` by `Spec`.
entry_of_spec :: proc "contextless" (spec: Spec) -> (entry: Format_Entry, ok: bool) {
	id, found := id_of_spec(spec)
	if !found {
		return {}, false
	}
	return entry_of_id(id)
}

// Resolves `entry_of` by `tape.Format_Id`.
entry_of_tape_id :: proc "contextless" (tid: tape.Format_Id) -> (entry: Format_Entry, ok: bool) {
	for m in FORMAT_META {
		if m.tape_id == tid {
			return entry_of_id(m.id)
		}
	}
	return {}, false
}

// Resolves `entry_of` from a runtime `^tape.Format` handle (making engine the central runtime dispatcher).
entry_of_format :: proc "contextless" (fmt_handle: ^tape.Format) -> (entry: Format_Entry, ok: bool) {
	if fmt_handle == nil {
		return {}, false
	}
	return entry_of_tape_id(fmt_handle.id)
}

// Resolves a `Format_Entry` from `Format_Id`, `Spec`, `tape.Format_Id`, or `^tape.Format`.
entry_of :: proc {
	entry_of_id,
	entry_of_spec,
	entry_of_tape_id,
	entry_of_format,
}

// Converts a runtime `^tape.Format` handle back to `Spec`.
spec_of :: proc "contextless" (fmt_handle: ^tape.Format) -> (spec: Spec, ok: bool) {
	e, found := entry_of_format(fmt_handle)
	if !found {
		return nil, false
	}
	return e.spec, true
}

// Reports whether partial path scanning saves work for `spec`.
supports_scan :: proc "contextless" (spec: Spec) -> bool {
	e, ok := entry_of_spec(spec)
	return ok && e.supports_scan
}

// Case-insensitive ASCII equality helper with zero heap allocation.
@(private)
ascii_eq_fold :: proc "contextless" (a, b: string) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}

// Looks up a format by canonical name or alias (case-insensitive).
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

// Looks up both the `Format_Entry` and implied framing for a format name or alias
// (e.g. `"ndjson"` / `"jsonl"` -> `.Json` + `.Lines`, `"json-seq"` -> `.Json` + `.Seq`,
// `"csv"` -> `.Csv` + `.Lines`, `"cbor"` -> `.Cbor` + `.Concatenated`).
format_and_framing_by_name :: proc "contextless" (name: string) -> (entry: Format_Entry, framing: Framing, ok: bool) {
	entry, ok = format_by_name(name)
	if !ok {
		return {}, .Single, false
	}
	framing = entry.default_framing
	if entry.id == .Json {
		switch {
		case ascii_eq_fold(name, "ndjson"), ascii_eq_fold(name, "jsonl"), ascii_eq_fold(name, "ldjson"), ascii_eq_fold(name, "jsonlines"):
			framing = .Lines
		case ascii_eq_fold(name, "jsonseq"), ascii_eq_fold(name, "json-seq"), ascii_eq_fold(name, "rfc7464"):
			framing = .Seq
		}
	}
	return entry, framing, true
}
