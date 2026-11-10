package schema

import "core:strings"

// The drafts the reader takes, oldest first. A schema is read into one form whatever its draft: `definitions` is
// `$defs`, a tuple `items` is `prefixItems`, `additionalItems` is `items`, `dependencies` is `dependentRequired` and
// `dependentSchemas`, draft-04's boolean `exclusiveMinimum` makes `minimum` exclusive, `id` is `$id`, a plain-name
// fragment `$id` is an `$anchor`, and 2019-09's `$recursiveAnchor` and `$recursiveRef` are a dynamic anchor and
// reference. The table `KEYWORDS` says which keyword each draft has.
Draft :: enum u8 {
	D04,
	D06,
	D07,
	D2019_09,
	D2020_12,
}

// The vocabularies whose keywords a dialect has. A draft before 2019-09 has them all.
@(private)
Vocab :: enum u8 {
	Core,
	Applicator,
	Unevaluated,
	Validation,
	Format,
	// The meta-data vocabulary, whose `readOnly` and `writeOnly` the reader keeps.
	Meta,
	// The format-assertion vocabulary, which makes `format` assert.
	Format_Assert,
}

@(private)
Vocabs :: bit_set[Vocab; u8]

@(private)
ALL_VOCABS :: Vocabs{.Core, .Applicator, .Unevaluated, .Validation, .Format, .Meta}

@(private)
Vocabulary :: struct {
	name: string,
	set:  Vocabs,
}

@(private)
VOCAB_URI_2019 :: "https://json-schema.org/draft/2019-09/vocab/"
@(private)
VOCAB_URI_2020 :: "https://json-schema.org/draft/2020-12/vocab/"

// The standard vocabularies, under the URI prefix of their draft. Meta-data has only the keywords the reader keeps, and
// content none. In 2019-09 the applicator vocabulary holds the unevaluated keywords.
@(private, rodata)
VOCABS_2019 := [?]Vocabulary{{"core", {.Core}}, {"applicator", {.Applicator, .Unevaluated}}, {"validation", {.Validation}}, {"format", {.Format}}, {"meta-data", {.Meta}}, {"content", {}}}

@(private, rodata)
VOCABS_2020 := [?]Vocabulary {
	{"core", {.Core}},
	{"applicator", {.Applicator}},
	{"unevaluated", {.Unevaluated}},
	{"validation", {.Validation}},
	{"format-annotation", {.Format}},
	{"format-assertion", {.Format, .Format_Assert}},
	{"meta-data", {.Meta}},
	{"content", {}},
}

// The vocabularies the standard vocabulary URI `uri` gives, and whether it is one.
@(private)
vocabulary_of :: proc(uri: string) -> (set: Vocabs, known: bool) {
	if strings.has_prefix(uri, VOCAB_URI_2019) {
		for v in VOCABS_2019 {
			if v.name == uri[len(VOCAB_URI_2019):] {
				return v.set, true
			}
		}
	}
	if strings.has_prefix(uri, VOCAB_URI_2020) {
		for v in VOCABS_2020 {
			if v.name == uri[len(VOCAB_URI_2020):] {
				return v.set, true
			}
		}
	}
	return
}

// A keyword of the drafts from `first` to `last`, and the vocabulary it belongs to. A keyword in a draft that has no
// row for it is an unknown keyword, which is an annotation.
@(private)
Row :: struct {
	name:        string,
	vocab:       Vocab,
	first, last: Draft,
}

@(private, rodata)
KEYWORDS := [?]Row {
	{"$schema", .Core, .D04, .D2020_12},
	{"$id", .Core, .D06, .D2020_12},
	{"id", .Core, .D04, .D04},
	{"$ref", .Core, .D04, .D2020_12},
	{"$anchor", .Core, .D2019_09, .D2020_12},
	{"$dynamicRef", .Core, .D2020_12, .D2020_12},
	{"$dynamicAnchor", .Core, .D2020_12, .D2020_12},
	{"$recursiveRef", .Core, .D2019_09, .D2019_09},
	{"$recursiveAnchor", .Core, .D2019_09, .D2019_09},
	{"$vocabulary", .Core, .D2019_09, .D2020_12},
	{"$defs", .Core, .D2019_09, .D2020_12},
	{"definitions", .Core, .D04, .D07},
	{"prefixItems", .Applicator, .D2020_12, .D2020_12},
	{"items", .Applicator, .D04, .D2020_12},
	{"additionalItems", .Applicator, .D04, .D2019_09},
	{"contains", .Applicator, .D06, .D2020_12},
	{"additionalProperties", .Applicator, .D04, .D2020_12},
	{"properties", .Applicator, .D04, .D2020_12},
	{"patternProperties", .Applicator, .D04, .D2020_12},
	{"dependentSchemas", .Applicator, .D2019_09, .D2020_12},
	{"dependentRequired", .Validation, .D2019_09, .D2020_12},
	{"dependencies", .Applicator, .D04, .D07},
	{"propertyNames", .Applicator, .D06, .D2020_12},
	{"if", .Applicator, .D07, .D2020_12},
	{"then", .Applicator, .D07, .D2020_12},
	{"else", .Applicator, .D07, .D2020_12},
	{"allOf", .Applicator, .D04, .D2020_12},
	{"anyOf", .Applicator, .D04, .D2020_12},
	{"oneOf", .Applicator, .D04, .D2020_12},
	{"not", .Applicator, .D04, .D2020_12},
	{"unevaluatedItems", .Unevaluated, .D2019_09, .D2020_12},
	{"unevaluatedProperties", .Unevaluated, .D2019_09, .D2020_12},
	{"type", .Validation, .D04, .D2020_12},
	{"const", .Validation, .D06, .D2020_12},
	{"enum", .Validation, .D04, .D2020_12},
	{"multipleOf", .Validation, .D04, .D2020_12},
	{"maximum", .Validation, .D04, .D2020_12},
	{"exclusiveMaximum", .Validation, .D04, .D2020_12},
	{"minimum", .Validation, .D04, .D2020_12},
	{"exclusiveMinimum", .Validation, .D04, .D2020_12},
	{"maxLength", .Validation, .D04, .D2020_12},
	{"minLength", .Validation, .D04, .D2020_12},
	{"pattern", .Validation, .D04, .D2020_12},
	{"maxItems", .Validation, .D04, .D2020_12},
	{"minItems", .Validation, .D04, .D2020_12},
	{"uniqueItems", .Validation, .D04, .D2020_12},
	{"maxContains", .Validation, .D2019_09, .D2020_12},
	{"minContains", .Validation, .D2019_09, .D2020_12},
	{"maxProperties", .Validation, .D04, .D2020_12},
	{"minProperties", .Validation, .D04, .D2020_12},
	{"required", .Validation, .D04, .D2020_12},
	{"format", .Format, .D04, .D2020_12},
	{"readOnly", .Meta, .D07, .D2020_12},
	{"writeOnly", .Meta, .D07, .D2020_12},
}

// Whether `name` is a keyword in `draft` when the dialect's vocabularies include its own.
@(private)
is_keyword :: proc(name: string, draft: Draft, vocab: Vocabs) -> bool {
	for row in KEYWORDS {
		if row.name == name && row.first <= draft && draft <= row.last && row.vocab in vocab {
			return true
		}
	}
	return false
}
