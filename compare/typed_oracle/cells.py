#!/usr/bin/env python3
"""cells.py <arm-dir> [cases-per-shape] [seed]: differential of dsv.unmarshal against the old csv.unmarshal over generated,
mutated and directed texts. ORACLE_SPEC (csv, tsv, plain), ORACLE_NO_HEADER, ORACLE_DUPS, ORACLE_UNKNOWN, ORACLE_RAGGED,
ORACLE_COMMENT and ORACLE_ENUMS choose the read's options, and the arms read them too. ORACLE_PREFILL reads each case over
the value the first reads as. A read compares by its value, or by its refusal's kind, byte and path. The old tree is the
reference, and `accepted` names each difference the plan lists."""
import os, random, re, struct, subprocess, sys

armdir = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 1
SPEC = os.environ.get('ORACLE_SPEC', 'csv')
DELIM = '\t' if SPEC == 'tsv' else ','
RAGGED = bool(os.environ.get('ORACLE_RAGGED'))
COMMENT = bool(os.environ.get('ORACLE_COMMENT'))
NO_HEADER = bool(os.environ.get('ORACLE_NO_HEADER'))
EXTRA = ['seed'] if os.environ.get('ORACLE_PREFILL') else []

INT = '0 -0 +0 1 -1 +7 127 128 -128 -129 255 256 65535 65536 2147483647 2147483648 4294967296 99999999 100000000 1234567890123456 12345678901234567 9223372036854775807 9223372036854775808 -9223372036854775808 -9223372036854775809 18446744073709551615 18446744073709551616 99999999999999999999999 007 1.0 1e2 x - + 1- 1x'.split()
FLT = '0 -0 1 .5 -.5 1. . +1.5 -1.5 1e2 1E-2 1.5e+3 12.5 3.25 0.1 0.2 99999999.99999999 12345678.1234567 1234567.12345678 12345678.12345678 123456789.5 1.123456789 123456789012345 1234567890123456 123456789012345678 0.1234567890123456 1e400 -1e400 1e-400 3.71782910823822 16777217 16777219 1.401298464324817e-45 3.5e38 1.1.1 1e 1e+ Infinity NaN abc 0x10'.split()
TXT = ['true', 'false', 'True', 'FALSE', 'tru', 'truex', 'falsee', '1', 'x', 'a b', 'é', '😀', 'Red', 'Green', 'Blue', 'Purple', '7', '0', 'y' * 70]
ODD = ['"', 'a"b', '""', 'a,b', 'a\tb', 'a\nb', 'a\r\nb', ' 1', '1 ', 'a\\b', '\\']

STRUCT = ['id', 'small', 'level', 'ok', 'score', 'u', 'zz', 'name_past_thirteen_bytes', 'may', 'mays', 'color', 'cs', 'w', 'hex']
REQ = ['a', 'b', 'c', 'zz']
TABLE = ['id', 'ts', 'lat', 'lon', 'qty', 'price', 'score', 'ok', 'code']
MAP = ['p', 'q', 'r', 's']
SHAPES = [
    ('Cell_Rec', STRUCT), ('Cell_Req', REQ), ('Cell_Table', TABLE), ('Cell_Dyn', REQ), ('Cell_List', MAP), ('Cell_Maybes', MAP),
    ('Cell_Map', MAP), ('Cell_Ints', MAP),
]

def encode(text):
    """A cell in the spec's spelling, or None when the spec cannot hold the text."""
    if SPEC == 'csv':
        return '"' + text.replace('"', '""') + '"'
    if SPEC == 'tsv':
        return text.replace('\\', '\\\\').replace('\t', '\\t').replace('\n', '\\n').replace('\r', '\\r')
    return None if any(c in text for c in ',\r\n') else text

VALID = {'id': '1 -5 +7 0 123456789 9007199254740993'.split(), 'ts': '1700000000 42'.split(), 'qty': '3 12'.split(), 'small': '1 -128 127'.split(),
         'w': '0 65535'.split(), 'may': '5 -7'.split(), 'a': '1 -3'.split(), 'u': '1.5 2 3.25e2'.split(), 'zz': ['a'], 'cs': ['c s', 'x'],
         'score': '1.5 -2.25 3e2'.split(), 'lat': ['37.5'], 'lon': ['-122.25'], 'price': ['9.99', '0.1'], 'ok': ['true', 'false'],
         'color': ['Red', 'Blue'], 'name_past_thirteen_bytes': ['7', '4294967295'], 'c': ['1.5', '2'], 'hex': ['ff', '10']}

def cell(r, col, clean=False):
    if clean and col in VALID:
        return '' if r.random() < .1 else r.choice(VALID[col])
    v = r.choice(INT + FLT + TXT + ODD)
    if col in ('id', 'small', 'u', 'w', 'ts', 'qty', 'may') and r.random() < .7:
        v = r.choice(INT)
    if col in ('score', 'lat', 'lon', 'price') and r.random() < .7:
        v = r.choice(FLT)
    if col in ('ok', 'color') and r.random() < .7:
        v = r.choice(TXT)
    if r.random() < .12:
        return ''
    needs = any(c in v for c in DELIM + '"\r\n\\')
    if SPEC == 'csv':
        return encode(v) if needs or r.random() < .3 else v
    if needs or r.random() < .05:
        e = encode(v)
        return e if e is not None else 'x'
    return v

def case(r, columns):
    cols = r.sample(columns, r.randrange(1, len(columns) + 1))
    if r.random() < .12:
        cols.append(r.choice(cols))
    if NO_HEADER:
        cols = columns[:r.randrange(1, len(columns) + 1)]
    head = DELIM.join(encode(c) if SPEC == 'csv' and r.random() < .1 else c for c in cols)
    eol = r.choice(['\n', '\r\n'])
    rows = [] if NO_HEADER else [head]
    if COMMENT and r.random() < .3:
        rows.insert(0, '#' + r.choice(['x', '"', 'a,b']))
    if r.random() < .05:
        rows = []
    clean = r.random() < .6
    for _ in range(r.randrange(0, 5)):
        row = [cell(r, c, clean) for c in cols]
        chance = .3 if RAGGED else .02
        if r.random() < chance:
            row.append('1')
        if r.random() < chance and len(row) > 1:
            row.pop()
        rows.append(DELIM.join(row))
        if COMMENT and r.random() < .2:
            rows.append('#' + r.choice(['y', '"', 'a,b']))
        if r.random() < .05:
            rows.append('')
    s = eol.join(rows) + (eol if r.random() < .8 else '')
    b = s.encode('utf8')
    if r.random() < .05:
        b = b'\xef\xbb\xbf' + b
    if r.random() < .1:
        b = bytearray(b)
        for _ in range(r.randrange(1, 3)):
            if b:
                b[r.randrange(len(b))] = r.choice(b'",\t\n\r\\\xff0a')
        b = bytes(b)
    return b

def directed(columns):
    first = columns[0]
    out = ['', '\n', '\r\n', '\n\n', '\xef\xbb\xbf', '#c\n', first, first + '\n', first + '\r\n', '\n' + first + '\n1\n', first + '\n\n1\n\n',
           '"' + first, first + '\n"', first + '\n"1', first + '\n1\r', first + '\n1\rx\n', first + '\n""\n', first + '\n"1"\n',
           first + '\n"true"\n', first + '\n\n', first + '\n,\n', ',\n1\n', first + DELIM + first + '\n1' + DELIM + '2\n',
           first + DELIM + first + '\n' + DELIM + '2\n', first + DELIM + first + '\n1' + DELIM + '\n']
    return [c.encode('latin1') if c.startswith('\xef') else c.encode() for c in out]

def row_of(line):
    """A refusal's row: the path's leading index, or None."""
    path = line.split(' ')[3]
    return path[:path.index(']') + 1] if path.startswith('[') else None

def at_of(line):
    """A refusal's byte."""
    return int(line.split(' ')[2])

def repeats_a_column(text):
    """Whether the header names a column twice."""
    if NO_HEADER:
        return False
    lines = text.removeprefix(b'\xef\xbb\xbf').decode('utf8', 'replace').splitlines()
    head = next((l for l in lines if not (COMMENT and l.startswith('#'))), '')
    names = [n.strip('"') for n in head.split(DELIM)]
    return len(set(names)) < len(names)

POSITION_COLUMN = re.compile(r'"[1-9][0-9]*":("(?:[^"\\\\]|\\\\.)*"|[^,>]*),')
POSITION_STEP = re.compile(r'^R \w+ \d+ \[\d+\]\.[1-9][0-9]*$')

def accepted(old, new, text):
    """The reason a difference is a listed one, or None."""
    # Every cell of a repeated column is judged, where the old tree judged only the one it kept, so the walk refuses
    # at the first bad cell of either.
    if new.startswith('R ') and (not old.startswith('R ') or at_of(new) < at_of(old)) and repeats_a_column(text):
        return 'repeated column judged'
    # The walk puts a quoted field never closed at its opening quote, and the old tree at the text's end.
    if old.startswith('R Walk') and new.startswith('R Walk') and at_of(new) < at_of(old) and text[at_of(new):at_of(new) + 1] == b'"':
        return 'unclosed quote at its opening quote'
    # Under `.Ragged` with a header a wide record's cells past the header's last are columns named by their 1-based
    # position, which are read and judged, where the old tree dropped them.
    if RAGGED and not NO_HEADER:
        if not new.startswith('R ') and POSITION_COLUMN.sub('', new) == POSITION_COLUMN.sub('', old):
            return 'wide record under ragged'
        if POSITION_STEP.search(new) and (not old.startswith('R ') or at_of(new) < at_of(old)):
            return 'wide record under ragged'
    if not (old.startswith('R ') and new.startswith('R ')):
        return None
    # A headless text's columns are the fields in order, so a required field past the first record's width is missing
    # from that row, where the old tree refuses at the columns before reading the record.
    if NO_HEADER and old.startswith('R Missing_Field') and row_of(old) is None:
        return 'headless required past the width'
    # The cells are read as the walk passes them, so two faults in one row refuse by the first in the text. The old tree
    # judges a record's shape, then its cells, then its empty required cells. Only faults of two kinds are explained so, and
    # two of one kind compare by byte and path.
    same_row = row_of(old) is not None and row_of(old) == row_of(new)
    if same_row and old.split(' ')[1] != new.split(' ')[1]:
        return 'first fault of a row'
    # The walk puts a field count fault at the line's end or the delimiter past the width, as `docs/walk.md` says, and the
    # old tree at the record's first byte.
    if same_row and old.startswith('R Width') and new.startswith('R Width') and at_of(new) >= at_of(old):
        return 'field count past the first byte'
    # Of a row's empty or short required cells, the first column refuses, where the old tree took the first field. A short
    # row's fall at its one end byte.
    if same_row and old.startswith('R Missing_Field') and new.startswith('R Missing_Field') and at_of(new) <= at_of(old):
        return 'empty required cells in text order'
    return None

bad = crashes = 0
why = {}
only = os.environ.get('ORACLE_SHAPES')
for shape, columns in SHAPES:
    if only and shape not in only.split(','):
        continue
    r = random.Random(SEED)
    cs = directed(columns) + [case(r, columns) for _ in range(N)]
    f = os.path.join(armdir, 'cells.' + shape + '.' + str(os.getpid()))
    with open(f, 'wb') as o:
        for c in cs:
            o.write(struct.pack('<I', len(c)) + c)
    res = {}
    for arm in ('old', 'new'):
        p = subprocess.run([os.path.join(armdir, arm), 'oracle', shape, f] + EXTRA, capture_output=True, timeout=900)
        res[arm] = p.stdout.decode('latin1').split('\x1e\n')[:-1]
        if p.returncode != 0 or len(res[arm]) != len(cs):
            crashes += 1
            at = min(len(res[arm]), len(cs) - 1)
            print(shape, arm, 'rc', p.returncode, 'after', len(res[arm]), repr(cs[at][:200]))
            print(p.stderr.decode('latin1')[-300:])
    os.remove(f)
    same = refused = 0
    kinds = {}
    for i, (a, b) in enumerate(zip(res['old'], res['new'])):
        refused += a.startswith('R ')
        if a == b:
            same += 1
        elif reason := accepted(a, b, cs[i]):
            why[reason] = why.get(reason, 0) + 1
        else:
            bad += 1
            kinds.setdefault((a.split(' ')[1][:12] if a.startswith('R ') else 'ok', b.split(' ')[1][:12] if b.startswith('R ') else 'ok'), []).append(i)
    for k, v in sorted(kinds.items(), key=lambda kv: -len(kv[1])):
        i = min(v, key=lambda c: len(cs[c]))
        print(shape, len(v), 'x', k)
        print('   ', repr(cs[i][:200]))
        print('    old', res['old'][i][:200])
        print('    new', res['new'][i][:200])
    print('==', shape, len(res['old']), 'same', same, 'refused', refused, flush=True)
print('total differ', bad, 'crashes', crashes, 'listed', why)
sys.exit(1 if bad or crashes else 0)
