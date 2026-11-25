// Error types, JSON Pointer parsing, member-name lookup, and shared value/document helpers.
package schema

import "base:runtime"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

// Why a schema operation failed.
Error_Kind :: enum u8 {
	None,
	Bad_Schema,
	Unsupported,
	Bad_Option,
	No_Sample,
	No_Invalid_Sample,
	No_Memory,
	Compile,
	Parse,
}

// Structured error returned by schema reading, compilation, writing, sampling, and codegen.
// Call `error_destroy` when `owned` is true (or always — it is safe on zero/non-owned errors).
Error :: struct {
	kind:         Error_Kind,
	at:           u64,
	keyword:      string,
	message:      string,
	path:         []tape.Step,
	compile_err:  check.Compile_Error,
	tape_err:     tape.Error,
	owned:        bool,
	allocator:    runtime.Allocator,
}

error_destroy :: proc(e: ^Error) {
	if e == nil || !e.owned {
		if e != nil {
			e^ = {}
		}
		return
	}
	a := e.allocator
	delete(e.keyword, a)
	delete(e.message, a)
	for s in e.path {
		if nm, ok := s.(tape.Name); ok {
			delete(string(nm), a)
		}
	}
	delete(e.path, a)
	e^ = {}
}

@(private)
make_error :: proc(kind: Error_Kind, keyword, message: string, at: u64 = 0, path: []tape.Step = nil, allocator := context.allocator) -> Error {
	if kind == .None {
		return {}
	}
	if allocator.procedure == nil {
		return {kind = kind, at = at, keyword = keyword, message = message}
	}
	kw, _ := strings.clone(keyword, allocator)
	msg, _ := strings.clone(message, allocator)
	steps: []tape.Step
	if len(path) > 0 {
		steps = steps_clone(path, allocator)
	}
	return {
		kind      = kind,
		at        = at,
		keyword   = kw,
		message   = msg,
		path      = steps,
		owned     = true,
		allocator = allocator,
	}
}

// Clones `steps` (including `Name` strings) into `allocator`.
@(private)
steps_clone :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> []tape.Step {
	if len(steps) == 0 {
		return nil
	}
	out := make([]tape.Step, len(steps), allocator)
	for s, i in steps {
		if nm, ok := s.(tape.Name); ok {
			cp, _ := strings.clone(string(nm), allocator)
			out[i] = tape.Name(cp)
		} else {
			out[i] = s
		}
	}
	return out
}

// Index of `rules.Member` slice by name for O(1) lookup, chaining duplicates.
@(private)
Member_Names :: struct {
	first: map[string]int,
	next:  [dynamic]int,
}

@(private)
member_names :: proc(members: []rules.Member, allocator: runtime.Allocator) -> (m: Member_Names) {
	m.first = make(map[string]int, len(members), allocator)
	m.next = make([dynamic]int, len(members), allocator)
	for i := len(members) - 1; i >= 0; i -= 1 {
		name := members[i].name
		prev, has := m.first[name]
		m.next[i] = prev if has else -1
		m.first[name] = i
	}
	return
}

@(private)
first_named :: proc(m: ^Member_Names, name: string) -> int {
	if idx, ok := m.first[name]; ok {
		return idx
	}
	return -1
}

@(private)
next_named :: proc "contextless" (m: ^Member_Names, k: int) -> int {
	if k < 0 || k >= len(m.next) {
		return -1
	}
	return m.next[k]
}

// One RFC 6901 JSON Pointer token (either an array index or an object member name).
@(private)
Pointer_Token :: struct {
	name:      string,
	index:     int,
	has_index: bool,
}

// Parses an RFC 6901 JSON Pointer (`""` or `"/a/0/b~1c"`). Returns tokens allocated from `allocator`.
@(private)
parse_json_pointer :: proc(ptr: string, allocator: runtime.Allocator) -> (tokens: []Pointer_Token, ok: bool) {
	if ptr == "" {
		return nil, true
	}
	if ptr[0] != '/' {
		return nil, false
	}
	out := make([dynamic]Pointer_Token, allocator)
	rest := ptr[1:]
	for {
		slash := strings.index_byte(rest, '/')
		raw := rest if slash < 0 else rest[:slash]
		decoded, dec_ok := decode_pointer_token(raw, allocator)
		if !dec_ok {
			for t in out {
				delete(t.name, allocator)
			}
			delete(out)
			return nil, false
		}
		idx, is_idx := parse_array_index(decoded)
		append(&out, Pointer_Token{name = decoded, index = idx, has_index = is_idx})
		if slash < 0 {
			break
		}
		rest = rest[slash + 1:]
	}
	return out[:], true
}

@(private)
decode_pointer_token :: proc(raw: string, allocator: runtime.Allocator) -> (string, bool) {
	if strings.index_byte(raw, '~') < 0 {
		s, err := strings.clone(raw, allocator)
		return s, err == nil
	}
	b := strings.builder_make(0, len(raw), allocator)
	for i := 0; i < len(raw); i += 1 {
		if raw[i] != '~' {
			strings.write_byte(&b, raw[i])
			continue
		}
		if i + 1 >= len(raw) {
			strings.builder_destroy(&b)
			return "", false
		}
		switch raw[i + 1] {
		case '0':
			strings.write_byte(&b, '~')
		case '1':
			strings.write_byte(&b, '/')
		case:
			strings.builder_destroy(&b)
			return "", false
		}
		i += 1
	}
	return strings.to_string(b), true
}

@(private)
parse_array_index :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	if s == "0" {
		return 0, true
	}
	if s[0] < '1' || s[0] > '9' {
		return 0, false
	}
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	v, ok := strconv.parse_int(s, 10)
	return v, ok && v >= 0
}

// Reads decoded string text of token `t` from `doc` into `allocator`.
@(private)
doc_token_string :: proc(doc: ^tape.Document, t: tape.Token, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	if t.kind != .String && t.kind != .Plain && t.role != .Key {
		return "", false
	}
	buf: [256]u8 = ---
	if text, tok := tape.node_text(doc, t, buf[:]); tok {
		cp, err := strings.clone(text, allocator)
		return cp, err == nil
	}
	room := tape.text_room(doc, t)
	if room <= 0 {
		room = int(t.n)
	}
	tmp, err := make([]u8, room, allocator)
	if err != nil {
		return "", false
	}
	text, tok := tape.node_text(doc, t, tmp)
	if !tok {
		delete(tmp, allocator)
		return "", false
	}
	if raw_data(text) == raw_data(tmp) && len(text) == len(tmp) {
		return text, true
	}
	cp, cerr := strings.clone(text, allocator)
	delete(tmp, allocator)
	return cp, cerr == nil
}

// Reads string node text from `doc` into `allocator`.
@(private)
doc_node_string :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	if at == tape.NO_NODE || int(at) >= len(doc.nodes) {
		return "", false
	}
	return doc_token_string(doc, doc.nodes[at], allocator)
}

// Reads object member key text from a `tape.next_child` result, supporting `Tabular_Ext` cell keys.
@(private)
doc_child_key_string :: proc(rd: tape.Reader, it: tape.Children, k: tape.Node_Index, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	if k == tape.NO_NODE && it.keys_n != 0 {
		return doc_token_string(rd.doc, tape.cell_key(rd, it), allocator)
	}
	return doc_node_string(rd.doc, k, allocator)
}

// Reads exact decimal text of a number node of `doc` into `allocator`.
@(private)
doc_node_number_text :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	if at == tape.NO_NODE || int(at) >= len(doc.nodes) || doc.nodes[at].kind != .Number {
		return "", false
	}
	buf: [128]u8 = ---
	raw_txt, owned, tok := rules.value_number_text(rules.Node_Ref{doc, at}, buf[:], allocator)
	if !tok {
		return "", false
	}
	txt := raw_txt[1:] if len(raw_txt) > 0 && raw_txt[0] == '+' else raw_txt
	cp, err := strings.clone(txt, allocator)
	if owned {
		delete(raw_txt, allocator)
	}
	return cp, err == nil
}

// Checks whether all elements of array node `at` of `doc` are pairwise distinct under JSON Schema equality.
@(private)
doc_array_unique :: proc(doc: ^tape.Document, at: tape.Node_Index, scratch: runtime.Allocator) -> (unique: bool, ok: bool) {
	r := tape.Reader{doc = doc}
	it, p, err := tape.children(r, at, scratch)
	if err != nil {
		return false, false
	}
	defer tape.destroy_children(&it)
	if p != .Found {
		return true, true
	}
	elems := make([dynamic]tape.Node_Index, scratch)
	defer delete(elems)
	for {
		_, ch, cp := tape.next_child(r, &it)
		if cp != .Found {
			break
		}
		append(&elems, ch)
	}
	if len(elems) <= 1 {
		return true, true
	}
	seen := make(map[u64][dynamic]tape.Node_Index, len(elems), scratch)
	defer {
		for _, bucket in seen {
			delete(bucket)
		}
		delete(seen)
	}
	for idx in elems {
		v := rules.Node_Ref{doc, idx}
		h, herr := rules.value_hash(v, .Last, scratch)
		if herr != nil {
			return false, false
		}
		if bucket, exists := seen[h]; exists {
			for prev in bucket {
				eq, eerr := rules.value_equal(rules.Node_Ref{doc, prev}, v, .Last, scratch)
				if eerr != nil {
					return false, false
				}
				if eq {
					return false, true
				}
			}
			append(&bucket, idx)
			seen[h] = bucket
		} else {
			b := make([dynamic]tape.Node_Index, 0, 1, scratch)
			append(&b, idx)
			seen[h] = b
		}
	}
	return true, true
}
