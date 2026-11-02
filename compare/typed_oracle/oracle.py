#!/usr/bin/env python3
"""oracle.py <arm-dir> [cases-per-shape] [seed] [arm]: differential of next's read against the old unmarshal. ORACLE_PREFILL
reads each case over the value the first reads as. ORACLE_FORMS is 1 for JSONC's forms, 2 for JSON5's too. ORACLE_DUPS
(first, refuse) and ORACLE_UNKNOWN choose the read's options, and the arms read them too. Makes structure-aware
and byte-level mutants of each shape's seed, runs both arms over the same case file and reports every case they read
differently, or that one arm crashes on. The old tree's refusals and values are the reference."""
import json, os, random, re, struct, subprocess, sys

armdir = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 1
ARM = sys.argv[4] if len(sys.argv) > 4 else 'd'
EXTRA = ['seed'] if os.environ.get('ORACLE_PREFILL') else []
REF = os.environ.get('ORACLE_REF', 'o')
# 1 writes JSONC's forms into the cases, 2 JSON5's too.
FORMS = int(os.environ.get('ORACLE_FORMS', '0'))

class Raw(str):
    pass

INTS = '0 -0 1 -1 7 127 128 -128 -129 255 256 300 32767 32768 -32769 65535 65536 2147483647 2147483648 -2147483649 4294967295 4294967296 9007199254740993 9223372036854775807 9223372036854775808 -9223372036854775808 -9223372036854775809 18446744073709551615 18446744073709551616 12345678901234567890 123456789012345678901 99999999999999999999999 0000 007 1.0 1.5 1e2 1E2 1e0 -1e0 1.0e1 0e0 0.0 -0.0'.split()
FLOATS = '0.1 0.2 0.30000000000000004 1.7976931348623157e308 1.7976931348623159e308 5e-324 2.4703282292062328e-324 2.2250738585072014e-308 2.2250738585072012e-308 1e400 -1e400 1e-400 1.1e-30 9007199254740993 9007199254740992.5 123456789012345678 1234567890.123456789 1.2345678901234567e22 8.5e15 0.000001 1e22 1e23 1e-22 123456789012345 1234567890123456 0.1234567890123456 0.123456789012345 100000000000000000000000000000000.5 3.4028235e38 3.5e38 1e39 1.401298464324817e-45 1e-46'.split()
BAD = ['01', '1.', '-', '1e', '1e+', '.5', '+1', 'tru', 'nul', 'falsee', 'truex', 'NaN', 'Infinity', "'x'", '"\\q"', '"\\ud800"', '"\\udc00x"', '"\\u12"', '"unterminated', '"a\nb"', '"\xff"']
STRS = ['""', '"x"', '"a\\nb"', '"\\u00e9"', '"\\ud83d\\ude00"', '"é"', '"\\""', '"\\\\"', '"' + 'y' * 40 + '"', '"' + 'y' * 70 + '\\n"', '"😀"', '"a\\/b"']
OTHER = ['null', 'true', 'false', '{}', '[]', '[1]', '[[]]', '{"a":1}', '[null]', '[1,2,3,4]', '[1,2,3,4,5,6,7,8,9]', '{"id":1}', '{"":1}']
VALUES = INTS + FLOATS + BAD + STRS + OTHER
if FORMS == 2:
    VALUES += ['+1', '-.5', '.5', '5.', '+5.e1', '0x10', '-0x10', '0XFF', '+0x7f', '0xFFFFFFFFFFFFFFFF', '0x1FFFFFFFFFFFFFFFF', 'Infinity', '-Infinity', '+Infinity', 'NaN', '-NaN', '+NaN', "'x'", "'it\\'s'", "'a\"b'", "'\\x41'", '"\\x41"', "'a\\\nb'", '"\\v\\0"', "'é'", "''", '/**/1', '1/**/', '[1,]', '{id:1,}', "{'id':1}", '{$a_b:1}', '{\\u0069d:1}']

rec = {"id": 1, "small": 2, "level": "x", "ok": True, "score": 1.5, "u": 3}
inner = {"a": 1, "b": [1, 2, 3], "c": ["p", "q"]}
mix = {"r": rec, "i": inner, "xs": [inner, inner], "ys": [1.5, 2], "m": {"k": rec, "l": rec}, "grid": [[1, 2], [3, 4]],
       "a_very_long_field_name": 9, "w": 18446744073709551615, "big": -9223372036854775808, "f": 2.5}
tree = {"v": 1, "kids": [{"v": 2, "kids": [{"v": 3, "kids": [], "by": {}}], "by": {}}], "by": {"a": {"v": 4, "kids": [], "by": {"b": {"v": 5}}}}}
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'next', 'bench', 'fixtures', 'corpus', '')
tw = json.load(open(root + 'twitter.json', encoding='utf8'))
tw = {"statuses": tw["statuses"][:2]}
citm = json.load(open(root + 'citm_catalog.json', encoding='utf8'))
small = {}
for k, v in citm.items():
    if isinstance(v, dict):
        small[k] = dict(list(v.items())[:2])
    elif isinstance(v, list):
        small[k] = v[:2]
    else:
        small[k] = v
point = {"x": 1, "y": 2}
opt = {"a": 1, "b": rec, "c": "s", "d": [1, 2], "e": "Green", "f": point, "g": [point, None, point], "h": point, "i": [1, None, 3],
       "j": {"p": point, "q": None}, "k": {"a": 2, "b": None, "e": "Blue", "k": {"e": "Red", "f": None}}, "l": {"u": 1}, "m": ["t"], "n": [1, None]}
feat = {"base_id": 1, "base_name": "n", "ren": 2, "skipped": 3, "e": "Blue", "es": ["Red", "Blue"], "bs": [0, 3, 11], "ca": [1, 2],
        "cs": "c", "mi": {"1": "a", "-2": "b"}, "me": {"Green": 1}, "mu": {"200": True}, "bw": True, "bn": False, "u": [1, 2], "nn": "s",
        "r": {"a": [1, "x"]}, "rs": [1, "t", None, [{}]], "dg": 12345678901234567890123}
req = {"a": 1, "b": "x", "c": {"a": 2, "b": "y"}, "d": [{"a": 3, "b": "z"}]}
wide = {"f%d" % i: i for i in range(69)}
wide["f69"] = [1, 2]
wide["f70"] = rec
holder = {"t": {"type": "Tag_A", "x": 1}, "ts": [{"y": "s", "type": "b"}, {"type": "Tag_A", "x": 2}], "p": {"type": "b", "y": "t"}}
hooked = {"v": "abc", "vs": ["", 12, {"k": [1]}, [2], None, True]}
anys = {"a": {"k": [1, "x", None, True, 1.5]}, "d": 5, "l": [1, -0.0, 18446744073709551615, 1e400, 123456789012345678901234567890, "s", {"z": {}}, []]}
SHAPES = [('Feat', feat), ('Req', req), ('Wide', wide), ('Holder', holder), ('Hooked', hooked), ('Anys', anys), ('Opt', opt), ('Rec', rec), ('Recs', [rec, rec, rec]), ('Mix', mix), ('Tree', tree), ('Twitter', tw), ('CITM', small),
          ('Int', 5), ('Text', "abc"), ('Grid', [[1.5, 2], [], [3]])]

def write(v, r, sep):
    if isinstance(v, Raw):
        return str(v)
    if isinstance(v, dict):
        items = [form_key(k, r) + sep[1] + write(x, r, sep) for k, x in (v.pairs if isinstance(v, Obj) else v.items())]
        return '{' + sep[2] + sep[0].join(items) + sep[3] + '}'
    if isinstance(v, list):
        return '[' + sep[2] + sep[0].join(write(x, r, sep) for x in v) + sep[3] + ']'
    return json.dumps(v, ensure_ascii=r.random() < .5)

def write_str(k, r):
    return k if isinstance(k, Raw) else json.dumps(k, ensure_ascii=False)

class Obj(dict):
    """A dict that keeps repeated and reordered members."""
    def __init__(self, pairs):
        self.pairs = pairs

def thaw(v):
    if isinstance(v, dict):
        return Obj([(k, thaw(x)) for k, x in v.items()])
    if isinstance(v, list):
        return [thaw(x) for x in v]
    return v

def nodes(v, out):
    if isinstance(v, Obj):
        out.append(v)
        for _, x in v.pairs:
            nodes(x, out)
    elif isinstance(v, list):
        out.append(v)
        for x in v:
            nodes(x, out)
    return out

def mutate(t, r):
    ns = nodes(t, [])
    if not ns:
        return Raw(r.choice(VALUES))
    n = r.choice(ns)
    op = r.randrange(9)
    if isinstance(n, list):
        if not n:
            n.append(Raw(r.choice(VALUES)))
        elif op < 4:
            n[r.randrange(len(n))] = Raw(r.choice(VALUES))
        elif op < 6:
            n.insert(r.randrange(len(n) + 1), r.choice(n))
        else:
            del n[r.randrange(len(n))]
        return t
    if not n.pairs:
        n.pairs.append(('id', Raw(r.choice(VALUES))))
        return t
    i = r.randrange(len(n.pairs))
    k, x = n.pairs[i]
    if op < 3:
        n.pairs[i] = (k, Raw(r.choice(VALUES)))
    elif op == 3:
        j = r.randrange(len(n.pairs))
        n.pairs[i], n.pairs[j] = n.pairs[j], n.pairs[i]
    elif op == 4:
        n.pairs.insert(r.randrange(len(n.pairs) + 1), n.pairs[i])
    elif op == 5:
        del n.pairs[i]
    elif op == 6:
        n.pairs.insert(i, (r.choice(['zz', 'unknown', 'id2', 'i', k + 'x', k[:-1], '']), Raw(r.choice(VALUES))))
    elif op == 7 and k:
        c = r.randrange(len(k))
        n.pairs[i] = (Raw('"' + k[:c].replace('"', '') + '\\u%04x' % ord(k[c]) + k[c + 1:].replace('"', '') + '"'), x)
    else:
        r.shuffle(n.pairs)
    return t

def bytes_mutant(b, r):
    b = bytearray(b)
    for _ in range(r.randrange(1, 4)):
        if not b:
            break
        i = r.randrange(len(b))
        op = r.randrange(5)
        if op == 0:
            b[i] = r.choice(b'{}[],:"\\ 0a-.e\n\xff\x00tfn')
        elif op == 1:
            del b[i]
        elif op == 2:
            b.insert(i, r.choice(b'{}[],:"\\ 0a-.e\n\xff\x00tfn'))
        elif op == 3:
            del b[i:]
        else:
            b[i:i] = b[r.randrange(len(b)):][:r.randrange(1, 9)]
    return bytes(b)

def form_key(k, r):
    if isinstance(k, Raw) or FORMS < 2 or not k.isidentifier() or r.random() < .5:
        return write_str(k, r)
    return k if r.random() < .6 else "'" + k + "'"

SEPS = [(',', ':', '', ''), (', ', ': ', '', ''), (',', ' : ', ' ', ' '), (',\n  ', ': ', '\n  ', '\n'), (' ,', ' :', '', ''), (',', ':\t', '\n', ' ')]

# A member repeated around one that came out of order, so the cursor matches the repeat with no key hook: it must still
# replace the first occurrence whole. Each pair holds two partial values of one field.
PARTS = {"r": ('{"id":1,"level":"a"}', '{"small":2}'), "i": ('{"a":1,"c":["p"]}', '{"b":[1,2,3]}'),
         "xs": ('[{"a":1}]', '[{"a":2}]'), "ys": ('[1,2]', '[3]'), "m": ('{"a":{"id":1}}', '{"b":{"u":2}}'),
         "grid": ('[[1,2],[3,4]]', '[[5,6],[7,8]]'), "f": ('1.5', '2.5')}

if FORMS:
    SEPS += [(',/*c*/', '/*d*/:/*e*/', '/*f*/', ',/*g*/'), (', // x\n', ' : ', '// y\n', ',\n'), (',', ':', '', ','), (',\n', ':', '\n', ',\n')]
if FORMS == 2:
    SEPS += [(',\u00a0', ':\u2028', '\ufeff', ' '), (',\x0b', ':\x0c', '', ',')]

def repeats():
    names = list(PARTS)
    out = []
    for i, y in enumerate(names):
        for x in names[:i]:
            a, c = PARTS[y]
            out.append('{"%s":%s,"%s":%s,"%s":%s}' % (y, a, x, PARTS[x][0], y, c))
            out.append('{"%s":%s,"%s":%s,"%s":%s}' % (x, PARTS[x][0], y, a, y, c))
            out.append('{"%s":%s,"%s":%s,"%s":%s,"%s":%s}' % (y, a, x, PARTS[x][0], y, c, x, PARTS[x][1]))
    return [c.encode() for c in out]

def halfway(r, n):
    """Decimals on and around the midpoints of f32, normal and subnormal, at 15 to 40 digits, one list of a value each."""
    from decimal import Decimal, getcontext
    from fractions import Fraction
    getcontext().prec = 120
    out = []
    for i in range(n):
        low = r.random() < .15
        m = r.randrange(1, 1 << 24) * 2 + 1 if low else r.randrange(1 << 23, 1 << 24) * 2 + 1
        h = Fraction(m) * Fraction(2) ** (-150 if low else r.randrange(-40, 40))
        d = Decimal(h.numerator) / Decimal(h.denominator)
        t = r.choice(['%.14e', '%.15e', '%.16e', '%.17e', '%.25e', '%.40e', '%.100e']) % d
        out.append(('{"ys":[%s%s]}' % ('-' if r.random() < .2 else '', t)).encode())
    return out

def cases(seed, r):
    out = [json.dumps(seed).encode('utf8')]
    if seed is mix:
        out += repeats() + halfway(r, 4000)
    for i in range(N - 1):
        t = thaw(json.loads(json.dumps(seed)))
        for _ in range(r.randrange(0, 4)):
            t = mutate(t, r)
        s = write(t, r, r.choice(SEPS)).encode('utf8', 'surrogateescape')
        if r.random() < .25:
            s = bytes_mutant(s, r)
        out.append(s)
    return out

# The old read writes a JSON5 value out again as JSON for a `Raw` or a hook, so NaN and Infinity refuse there, where next
# hands over the span. The old `Digits` of a JSON5 number past binary64 is a dangling slice.
def json5_span(shape, case):
    if FORMS != 2:
        return False
    if shape in ('Feat', 'Hooked'):
        return b'NaN' in case or b'Infinity' in case
    return shape == 'Anys' and re.search(rb'\de(3\d\d|4)', case) is not None

bad = crashes = accepted = 0
only = os.environ.get('ORACLE_SHAPES')
for shape, seed in SHAPES:
    if only and shape not in only.split(','):
        continue
    r = random.Random(SEED)
    cs = cases(seed, r)
    f = os.path.join(armdir, 'cases.' + shape)
    with open(f, 'wb') as o:
        for c in cs:
            o.write(struct.pack('<I', len(c)) + c)
    res = {}
    for arm in (REF, ARM):
        p = subprocess.run([os.path.join(armdir, arm), 'oracle', shape, f] + EXTRA, capture_output=True, timeout=600)
        res[arm] = p.stdout.decode('latin1').split('\n')[:-1]
        if p.returncode != 0:
            crashes += 1
            print(shape, 'arm', arm, 'rc', p.returncode, 'after', len(res[arm]), 'cases:', repr(cs[len(res[arm])][:200]))
            print(p.stderr.decode('latin1')[-300:])
    ok = refused = 0
    shown = 0
    why = []
    for i, (a, b) in enumerate(zip(res[REF], res[ARM])):
        if a == 'R':
            refused += 1
        if a == b:
            ok += 1
            continue
        bad += 1
        why.append(i)
    if why:
        one = os.path.join(armdir, 'case.one')
        kinds = {}
        with open(one, 'wb') as o:
            for i in why:
                o.write(struct.pack('<I', len(cs[i])) + cs[i])
        p = subprocess.run([os.path.join(armdir, REF), 'oracle', shape, one, 'why'], capture_output=True, timeout=600)
        lines = p.stderr.decode('latin1').split('\n')
        at = -1
        reason = {}
        for l in lines:
            if not l:
                continue
            if l.startswith('case '):
                at = int(l[5:])
            elif at >= 0:
                reason[at] = l[l.find('kind'):l.find('kind')+40] if 'kind' in l else l[:40]
        for w, i in enumerate(why):
            k = reason.get(w, 'old accepts')
            # The one accepted difference: next reads past a number beyond the old exponent limit in a skipped member.
            if 'Limit_Scale' in k and res[REF][i] == 'R' or json5_span(shape, cs[i]):
                bad -= 1
                accepted += 1
                continue
            kinds.setdefault(k[:60], []).append(i)
        for k, v in sorted(kinds.items(), key=lambda kv: -len(kv[1])):
            print(shape, len(v), 'x', k)
            i = min(v, key=lambda c: len(cs[c]))
            print('   ', i, repr(cs[i][:220]))
            print('   old', res[REF][i][:170])
            print('   new', res[ARM][i][:170])
    print('==', shape, len(res[REF]), len(res[ARM]), 'same', ok, 'refused', refused, flush=True)
print('total differ', bad, 'crashes', crashes, 'accepted', accepted)
sys.exit(1 if bad or crashes else 0)
