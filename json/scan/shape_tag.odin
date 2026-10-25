package scan

// The union tag pre-scan: an object's `r.union_tag` value read by spans, before the walk checks it.

import core_pkg "../../core"
import "walk"
import lex "lex"

// 1 + the struct arm of the tagged union op `op` that the object at `at` names in its `r.union_tag` member, or 0
// when it has none. The walk has not checked the object yet: this pre-scan reads its members by their spans, and
// one it cannot read ends the scan as if the tag were absent, so the walk's own result on it comes next. A
// tag that is no arm's name is `.Not_A_Member`. The key and the name compare decoded, as every key does.
shape_tag_arm :: proc(r: ^walk.Shape_Run, op: ^core_pkg.Shape_Op, at: u64) -> (k: u8, fault: core_pkg.Shape_Fault) {
	p, end, found := shape_tag_span(r, at)
	if !found {
		return
	}
	for arm, i in r.fields[op.elem:][:op.count] {
		if len(arm.name) > 0 && name_equals(r.src, u64(p), u64(end), arm.name) {
			return u8(i + 1), .None
		}
	}
	return 0, .Not_A_Member
}

// The extent `src[p:end]` of the `r.union_tag` member's value in the object opening at `at`, read by spans.
shape_tag_span :: proc(r: ^walk.Shape_Run, at: u64) -> (p, end: int, found: bool) {
	src := r.src
	p = shape_skip_space(src, int(at) + 1)
	for p < len(src) && src[p] == '"' {
		key_end := lex.value_end(src, p, VC_STRING, 0)
		if key_end < 0 {
			return
		}
		is_tag := name_equals(src, u64(p), u64(key_end), r.union_tag)
		p = shape_skip_space(src, key_end)
		if p >= len(src) || src[p] != ':' {
			return
		}
		p = shape_skip_space(src, p + 1)
		if p >= len(src) || lex.VCLASS[src[p]] == VC_NONE {
			return
		}
		end = lex.value_end(src, p, lex.VCLASS[src[p]], walk.MAX_DEPTH)
		if end < 0 {
			return
		}
		if is_tag {
			return p, end, true
		}
		p = shape_skip_space(src, end)
		if p >= len(src) || src[p] != ',' {
			return
		}
		p = shape_skip_space(src, p + 1)
	}
	return
}

// The syntax fault of the tag value in the object opening at `at`, or nil when it is well-formed (or there is
// none): the result a union's `.Not_A_Member` at its `{` gives way to, since a value that is read is checked
// before it is refused. The value is checked with the byte after it, which finishes a literal or a number as the
// walk sees it. A well-formed value there is only `.Trailing`. Called after the walk, with the refusal.
@(cold)
shape_tag_verdict :: proc(r: ^walk.Shape_Run, at: u64) -> Maybe(Error) {
	p, end, found := shape_tag_span(r, at)
	if !found {
		return nil
	}
	err, bad := scan_plain(r.src[p:min(end + 1, len(r.src))]).?
	if !bad || err.kind == .Trailing {
		return nil
	}
	err.offset += u64(p)
	return err
}
