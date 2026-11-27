// Error types, JSON Pointer parsing, member-name lookup, and shared value/document helpers.
package schema

import "base:runtime"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

Error_Kind :: enum u8 { None, Bad_Schema, Unsupported, Bad_Option, No_Sample, No_Invalid_Sample, No_Memory, Compile, Parse }

Error :: struct {
	kind:        Error_Kind,
	at:          u64,
	keyword:     string,
	message:     string,
	path:        []tape.Step,
	compile_err: check.Compile_Error,
	tape_err:    tape.Error,
	owned:       bool,
	allocator:   runtime.Allocator,
}

error_destroy :: proc(e: ^Error) {
	if e == nil { return }
	if e.owned {
		a := e.allocator
		delete(e.keyword, a)
		delete(e.message, a)
		for s in e.path { if nm, ok := s.(tape.Name); ok { delete(string(nm), a) } }
		delete(e.path, a)
	}
	e^ = {}
}

@(private)
make_error :: proc(kind: Error_Kind, keyword, message: string, at: u64 = 0, path: []tape.Step = nil, allocator := context.allocator) -> Error {
	if kind == .None { return {} }
	if allocator.procedure == nil { return {kind = kind, at = at, keyword = keyword, message = message} }
	kw, _ := strings.clone(keyword, allocator)
	msg, _ := strings.clone(message, allocator)
	return {kind = kind, at = at, keyword = kw, message = msg, path = steps_clone(path, allocator), owned = true, allocator = allocator}
}

@(private)
steps_clone :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> []tape.Step {
	if len(steps) == 0 { return nil }
	out := make([]tape.Step, len(steps), allocator)
	for s, i in steps {
		if nm, ok := s.(tape.Name); ok {
			cp, _ := strings.clone(string(nm), allocator)
			out[i] = tape.Name(cp)
		} else { out[i] = s }
	}
	return out
}

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
	return m.first[name] or_else -1
}

@(private)
next_named :: proc "contextless" (m: ^Member_Names, k: int) -> int {
	return m.next[k] if k >= 0 && k < len(m.next) else -1
}

@(private)
Pointer_Token :: struct {
	name:      string,
	index:     int,
	has_index: bool,
}

@(private)
parse_json_pointer :: proc(ptr: string, allocator: runtime.Allocator) -> ([]Pointer_Token, bool) {
	if ptr == "" { return nil, true }
	if ptr[0] != '/' { return nil, false }
	out := make([dynamic]Pointer_Token, allocator)
	rest := ptr[1:]
	for {
		slash := strings.index_byte(rest, '/')
		decoded, dec_ok := decode_pointer_token(rest if slash < 0 else rest[:slash], allocator)
		if !dec_ok {
			for t in out { delete(t.name, allocator) }
			delete(out)
			return nil, false
		}
		idx, is_idx := parse_array_index(decoded)
		append(&out, Pointer_Token{name = decoded, index = idx, has_index = is_idx})
		if slash < 0 { break }
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
		if raw[i] != '~' { strings.write_byte(&b, raw[i]); continue }
		if i + 1 >= len(raw) || (raw[i + 1] != '0' && raw[i + 1] != '1') { strings.builder_destroy(&b); return "", false }
		strings.write_byte(&b, '~' if raw[i + 1] == '0' else '/')
		i += 1
	}
	return strings.to_string(b), true
}

@(private)
parse_array_index :: proc(s: string) -> (int, bool) {
	if s == "0" { return 0, true }
	if len(s) == 0 || s[0] < '1' || s[0] > '9' { return 0, false }
	for c in transmute([]u8)s { if c < '0' || c > '9' { return 0, false } }
	v, ok := strconv.parse_int(s, 10)
	return v, ok && v >= 0
}

@(private)
doc_token_string :: proc(doc: ^tape.Document, t: tape.Token, allocator: runtime.Allocator) -> (string, bool) {
	if t.kind != .String && t.kind != .Plain && t.role != .Key { return "", false }
	buf: [256]u8 = ---
	if text, tok := tape.node_text(doc, t, buf[:]); tok {
		cp, err := strings.clone(text, allocator)
		return cp, err == nil
	}
	room := tape.text_room(doc, t)
	if room <= 0 { room = int(t.n) }
	tmp, err := make([]u8, room, allocator)
	if err != nil { return "", false }
	text, tok := tape.node_text(doc, t, tmp)
	if !tok { delete(tmp, allocator); return "", false }
	if raw_data(text) == raw_data(tmp) && len(text) == len(tmp) { return text, true }
	cp, cerr := strings.clone(text, allocator)
	delete(tmp, allocator)
	return cp, cerr == nil
}

@(private)
doc_node_string :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> (string, bool) {
	if at == tape.NO_NODE || int(at) >= len(doc.nodes) { return "", false }
	return doc_token_string(doc, doc.nodes[at], allocator)
}

@(private)
doc_child_key_string :: proc(rd: tape.Reader, it: tape.Children, k: tape.Node_Index, allocator: runtime.Allocator) -> (string, bool) {
	if k == tape.NO_NODE && it.keys_n != 0 { return doc_token_string(rd.doc, tape.cell_key(rd, it), allocator) }
	return doc_node_string(rd.doc, k, allocator)
}

@(private)
doc_node_number_text :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> (string, bool) {
	if at == tape.NO_NODE || int(at) >= len(doc.nodes) || doc.nodes[at].kind != .Number { return "", false }
	buf: [128]u8 = ---
	raw_txt, owned, tok := rules.value_number_text(rules.Node_Ref{doc, at}, buf[:], allocator)
	if !tok { return "", false }
	cp, err := strings.clone(raw_txt[1:] if len(raw_txt) > 0 && raw_txt[0] == '+' else raw_txt, allocator)
	if owned { delete(raw_txt, allocator) }
	return cp, err == nil
}

@(private)
doc_array_unique :: proc(doc: ^tape.Document, at: tape.Node_Index, scratch: runtime.Allocator) -> (bool, bool) {
	r := tape.Reader{doc = doc}
	it, p, err := tape.children(r, at, scratch)
	if err != nil { return false, false }
	defer tape.destroy_children(&it)
	if p != .Found { return true, true }
	seen := make(map[u64][dynamic]tape.Node_Index, 8, scratch)
	defer {
		for _, bucket in seen { delete(bucket) }
		delete(seen)
	}
	for {
		_, idx, cp := tape.next_child(r, &it)
		if cp != .Found { break }
		v := rules.Node_Ref{doc, idx}
		h, herr := rules.value_hash(v, .Last, scratch)
		if herr != nil { return false, false }
		bucket := seen[h]
		if bucket == nil { bucket.allocator = scratch }
		for prev in bucket {
			eq, eerr := rules.value_equal(rules.Node_Ref{doc, prev}, v, .Last, scratch)
			if eerr != nil { return false, false }
			if eq { return false, true }
		}
		append(&bucket, idx)
		seen[h] = bucket
	}
	return true, true
}
