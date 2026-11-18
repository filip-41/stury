// The format of a fixture by its file name, and the handles and plans the probes read and write it by. A probe keeps its
// constant-spec JSON calls for `.Json` and takes the format of any other file through `core`.
package formats

import "core:strings"
import core "../../core"
import typed "../../core/typed"
import cbor "../../cbor"
import dsv "../../dsv"
import html "../../html"
import json "../../json"
import toml "../../toml"
import xml "../../xml"
import yaml "../../yaml"

Kind :: enum {
	Json,
	Jsonc,
	Json5,
	Csv,
	Tsv,
	Yaml,
	Toml,
	Xml,
	Html,
	Cbor,
}

SUFFIXES := [Kind]string {
	.Json  = ".json",
	.Jsonc = ".jsonc",
	.Json5 = ".json5",
	.Csv   = ".csv",
	.Tsv   = ".tsv",
	.Yaml  = ".yaml",
	.Toml  = ".toml",
	.Xml   = ".xml",
	.Html  = ".html",
	.Cbor  = ".cbor",
}

// The format `path` is read as, by its suffix: any suffix but the ones named is JSON.
of_path :: proc(path: string) -> Kind {
	for k in Kind {
		if strings.has_suffix(path, SUFFIXES[k]) {
			return k
		}
	}
	return .Json
}

// The handle `core`'s format-agnostic calls read `k` by, or write it by with `writing`, which names the preferred
// (shortest) spelling of CBOR numbers.
handle :: proc(k: Kind, writing := false) -> core.As {
	switch k {
	case .Json:
		return json.as(.Json)
	case .Jsonc:
		return json.as(.Jsonc)
	case .Json5:
		return json.as(.Json5)
	case .Csv:
		return dsv.as(.Csv)
	case .Tsv:
		return dsv.as(.Tsv)
	case .Yaml:
		return yaml.as(.Yaml_1_2)
	case .Toml:
		return toml.as(.Toml_1_0)
	case .Xml:
		return xml.as(.Xml)
	case .Html:
		return html.as(.Document)
	case .Cbor:
		return cbor.as(.Preferred if writing else .Cbor)
	}
	return {}
}

// How the records of a text of `k` are framed: the documents of a YAML stream and the items of a CBOR sequence follow
// one another, and any other text has a record to a line.
framing :: proc(k: Kind) -> core.Framing {
	#partial switch k {
	case .Yaml, .Cbor:
		return .Concatenated
	}
	return .Lines
}

// The plan of `T` for format `k`, which writes `k` and reads through `typed.unmarshal_text`.
plan :: proc(T: typeid, k: Kind, writing := false) -> (typed.Plan, core.Error) {
	if k == .Json {
		return json.plan_make(T)
	}
	return typed.plan_make(T, handle(k, writing))
}

// The checks `schema.bind` takes to judge texts of format `k`.
checks :: proc(k: Kind) -> typed.Format_Checks {
	switch k {
	case .Json:
		return json.checks(.Json)
	case .Jsonc:
		return json.checks(.Jsonc)
	case .Json5:
		return json.checks(.Json5)
	case .Csv:
		return dsv.checks(.Csv)
	case .Tsv:
		return dsv.checks(.Tsv)
	case .Yaml:
		return yaml.checks(.Yaml_1_2)
	case .Toml:
		return toml.checks(.Toml_1_0)
	case .Xml:
		return xml.checks(.Xml)
	case .Html:
		return html.checks(.Document)
	case .Cbor:
		return cbor.checks(.Cbor)
	}
	return {}
}
