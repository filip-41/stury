package html

import core "../core"

// The tokenizer, the tree and the edit rule, for html/test's conformance tests and for a build with
// `-define:STURY_HTML_INTERNALS=true`. They are no part of the surface.

@(private)
INTERNALS :: #config(STURY_HTML_INTERNALS, false)

// The block below is the import's only user. A build without it has none.
_ :: core

when ODIN_TEST || INTERNALS {
	Internal_Token :: Html_Token
	Internal_Span :: Span
	Internal_Action :: Token_Action
	Internal_Content :: Content
	Internal_Tree :: Html_Tree
	Internal_Node :: Tree_Node
	Internal_Attribute_Namespace :: Attribute_Namespace
	Internal_Parse_Error :: Parse_Error

	internal_tokenize :: proc(src: []u8, h: ^$H, $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, start := Content.Data, last_start_tag := "", allocator := context.allocator) -> (hi: u64, fault: Maybe(core.Fault), stopped: bool) {
		return tokenize(src, h, on, start, last_start_tag, allocator = allocator)
	}

	internal_decode :: proc "contextless" (src: []u8, s: Span, buf: []u8) -> (text: string, ok: bool) #optional_ok {
		return decode(src, s, buf)
	}

	internal_decode_room :: proc "contextless" (s: Span) -> int {
		return decode_room(s)
	}

	internal_build :: proc(src: []u8, spec := Spec.Document, opts := Options{}, allocator := context.allocator) -> (Html_Tree, Maybe(core.Fault)) {
		return build_tree(src, spec, read_of(opts), allocator = allocator)
	}

	// The name of the encoding a byte order mark or the prescan finds, as the Encoding Standard names it.
	internal_sniff :: proc(src: []u8) -> (name: string, found: bool) {
		enc, _, _, ok := sniffed(src)
		return ENCODING_NAMES[enc], ok
	}

	// The name of a document's encoding, and whether the sniffing or a `meta` named one.
	internal_tree_encoding :: proc(t: ^Html_Tree) -> (name: string, found: bool) {
		return ENCODING_NAMES[t.encoding], !t.tentative
	}

	// The name of the encoding the label at byte `at` of `src` names, as a fault at a label points to it.
	internal_label :: proc(src: []u8, at: u64) -> (name: string, found: bool) {
		hi := int(at)
		for hi < len(src) && !is_space(src[hi]) && src[hi] != '"' && src[hi] != '\'' && src[hi] != ';' && src[hi] != '>' {
			hi += 1
		}
		enc, _, ok := encoding_of(src, int(at), hi)
		return ENCODING_NAMES[meta_named(enc)], ok
	}

	internal_tree_destroy :: proc(t: ^Html_Tree) {
		tree_destroy(t)
	}

	// The local name an element reads as, ASCII lowered and with SVG's mixed case restored.
	internal_element_name :: proc(t: ^Html_Tree, n: ^Tree_Node) -> string {
		if n.ns == .Svg {
			if f := foreign_name(t.src, n.name); .Svg_Element in f.kinds {
				return f.name
			}
		}
		return TAG_NAMES[n.tag] if n.tag != .Other else decoded(t, n.name, 0)
	}

	// The namespace and local name attribute `a` of element `n` reads as, adjusted for SVG and MathML.
	internal_attribute_name :: proc(t: ^Html_Tree, n: ^Tree_Node, a: ^Attribute) -> (ns: Attribute_Namespace, name: string) {
		if n.ns != .Html {
			f := foreign_name(t.src, a.name)
			if .Foreign_Attribute in f.kinds || .Svg_Attribute in f.kinds && n.ns == .Svg || .Math_Attribute in f.kinds && n.ns == .Math {
				return f.ns, f.name
			}
		}
		return .None, decoded(t, a.name, 0)
	}

	internal_decoded :: proc(t: ^Html_Tree, s: Span) -> string {
		return decoded(t, s, 0)
	}
}
