// Redaction policy, RFC 6901 JSON Pointer / wildcard path matching, and secret-safe formatting helpers.
package model

import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"

DEFAULT_REDACT_MASK :: "[REDACTED]"

Problem_Opts :: struct { redact: bool, redact_mask: string, redact_paths: []string }

@(private)
resolve_redact_mask :: proc "contextless" (mask: string) -> string { return mask if len(mask) > 0 else DEFAULT_REDACT_MASK }

@(private)
redact_steps_match :: proc(steps: []tape.Step, patterns: []string, match_prefix := false) -> bool {
	for pat in patterns {
		if len(pat) == 0 { if len(steps) == 0 || match_prefix { return true }; continue }
		if pat[0] != '/' { continue }
		rest, idx, ok := pat[1:], 0, true
		for {
			slash := strings.index_byte(rest, '/')
			seg := rest[:slash] if slash >= 0 else rest
			if idx >= len(steps) { ok = false; break }
			if seg != "*" {
				#partial switch v in steps[idx] {
				case tape.Name:  ok = pointer_segment_equals(seg, string(v))
				case tape.Index: buf: [24]u8 = ---; ok = seg == strconv.write_int(buf[:], i64(v), 10)
				case:            ok = false
				}
				if !ok { break }
			}
			idx += 1
			if slash < 0 { break }
			rest = rest[slash + 1:]
		}
		if ok && (idx == len(steps) || (match_prefix && idx < len(steps))) { return true }
	}
	return false
}

@(private)
pointer_segment_equals :: proc "contextless" (seg, name: string) -> bool {
	si, ni := 0, 0
	for si < len(seg) && ni < len(name) {
		c := seg[si]
		if c == '~' && si + 1 < len(seg) && (seg[si + 1] == '0' || seg[si + 1] == '1') {
			want := u8('/') if seg[si + 1] == '1' else u8('~')
			if name[ni] != want { return false }
			si += 2; ni += 1; continue
		}
		if c != name[ni] { return false }
		si += 1; ni += 1
	}
	return si == len(seg) && ni == len(name)
}

@(private)
redact_pointer_matches :: proc(pointer: string, patterns: []string) -> bool {
	for pat in patterns {
		if len(pat) == 0 { return true }
		if len(pointer) == 0 || pointer[0] != '/' || pat[0] != '/' { continue }
		pr, pa, ok := pointer[1:], pat[1:], true
		for {
			ps, as := strings.index_byte(pr, '/'), strings.index_byte(pa, '/')
			pseg, aseg := pr[:ps] if ps >= 0 else pr, pa[:as] if as >= 0 else pa
			if aseg != "*" && pseg != aseg { ok = false; break }
			if as < 0 { break }
			if ps < 0 { ok = false; break }
			pr, pa = pr[ps + 1:], pa[as + 1:]
		}
		if ok { return true }
	}
	return false
}
