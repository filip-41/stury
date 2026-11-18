// `doc-lexbor build|read|key FILE`: lexbor's HTML document of the text (WHATWG tree construction, UTF-8), then nothing, a
// visit of every value or the root key looked up in every object. The shape each lane reads is html_shape.hpp's.
#include "lexbor_shape.hpp"

int main(int argc, char** argv) { return html_shape::run_doc<Lexbor>(argc, argv, "doc-lexbor"); }
