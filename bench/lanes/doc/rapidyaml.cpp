// `doc-rapidyaml build|read|key FILE`: rapidyaml's parse_in_arena of the text into a Tree, then nothing, a visit of every
// value, or one find_child of the first key in every map. The tree filters each quoted and folded scalar in place, so its
// `val` is the decoded text, and a plain scalar is typed by the core schema in yaml_doc.h.
#define RYML_SINGLE_HDR_DEFINE_NOW
#include "rapidyaml_doc.h"

int main(int argc, char **argv) { return doc_main<Rapidyaml>(argc, argv, "doc-rapidyaml"); }
