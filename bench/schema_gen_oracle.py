#!/usr/bin/env python3
"""schema_gen_oracle.py: the Python `jsonschema` package, the oracle for the check over generated schemas.

    schema_gen_oracle.py PROBE [--seeds N] [--cases N] [--instances N]

PROBE is the built bench/schema_json. Each case is a random 2020-12 schema over every keyword the check judges, in-place
applicators, references, anchors, dynamic references and the unevaluated keywords included, and random instances, some
drawn from the constants the schema names. Formats are not asserted. The probe and jsonschema Draft202012Validator must
give the same verdict on every instance. A schema jsonschema cannot compile is counted apart, one the probe's check does
not bind is counted by the keyword it names, and one the probe cannot read is a difference.

Run it with the pinned package: make diff-schema-gen, which is
  uv run --offline --no-project --with jsonschema==4.26.0 python3 -I bench/schema_gen_oracle.py
Exits 1 on a difference.
"""
import argparse, json, random, re, subprocess, sys, tempfile

import jsonschema, referencing, referencing.jsonschema

KEYS = ["a", "b", "c", "ab"]
WORDS = ["", "a", "ab", "abc", "b", "ba"]
PATTERNS = ["^a", "b$", "^[ab]+$", "a.c", "^$"]
TYPES = ["null", "boolean", "integer", "number", "string", "array", "object"]
SCALARS = [None, True, False, 0, 1, 2, 3, 5, -1, 2.0, 0.5, 2.5, "", "a", "ab", "abc", "b"]


class Gen:
    def __init__(self, rng):
        self.rng, self.values, self.defs, self.anchor = rng, list(SCALARS), {}, False

    def value(self, depth=0):
        r = self.rng
        pick = r.random()
        if pick < 0.3:
            return r.choice(self.values)
        if depth > 2 or pick < 0.6:
            return r.choice(SCALARS)
        if pick < 0.8:
            return [self.value(depth + 1) for _ in range(r.randint(0, 4))]
        return {k: self.value(depth + 1) for k in r.sample(KEYS, r.randint(0, 3))}

    def literal(self):
        v = self.value(1)
        self.values.append(v)
        return v

    def schema(self, depth):
        r = self.rng
        if depth > 3 or r.random() < 0.1:
            return r.choice([True, False, {}, {"type": r.choice(TYPES)}])
        s = {}
        def sub():
            return self.schema(depth + 1)
        def has(p):
            return r.random() < p
        if has(0.4):
            s["type"] = r.choice(TYPES) if has(0.6) else r.sample(TYPES, r.randint(2, 3))
        if has(0.1):
            s["enum"] = [self.literal() for _ in range(r.randint(0, 3))]
        if has(0.1):
            s["const"] = self.literal()
        for k in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"):
            if has(0.08):
                s[k] = r.choice([0, 1, 2, 3, 5, 0.5, 2.5])
        if has(0.06):
            s["multipleOf"] = r.choice([2, 3, 0.5])
        for k in ("minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"):
            if has(0.07):
                s[k] = r.randint(0, 3)
        if has(0.1):
            s["pattern"] = r.choice(PATTERNS)
        def child():
            return {"$ref": "#"} if self.defs is not None and has(0.06) else sub()
        if has(0.15):
            s["properties"] = {k: child() for k in r.sample(KEYS, r.randint(1, 3))}
        if has(0.15):
            s["required"] = r.sample(KEYS, r.randint(1, 2))
        if has(0.06):
            s["patternProperties"] = {r.choice(["^a", "b$"]): sub()}
        if has(0.1):
            s["additionalProperties"] = child()
        if has(0.04):
            s["propertyNames"] = r.choice([{"pattern": r.choice(PATTERNS)}, {"maxLength": 1}, {"minLength": 2}, {"enum": KEYS[:2]}, sub()])
        if has(0.05):
            s["dependentRequired"] = {r.choice(KEYS): r.sample(KEYS, r.randint(0, 2))}
        if has(0.05):
            s["dependentSchemas"] = {r.choice(KEYS): sub()}
        if has(0.12):
            s["items"] = child()
        if has(0.07):
            s["prefixItems"] = [sub() for _ in range(r.randint(1, 3))]
        if has(0.08):
            s["contains"] = sub()
            for k in ("minContains", "maxContains"):
                if has(0.4):
                    s[k] = r.randint(0, 3)
        if has(0.06):
            s["uniqueItems"] = r.random() < 0.8
        for k in ("allOf", "anyOf", "oneOf"):
            if has(0.1):
                s[k] = [sub() for _ in range(r.randint(1, 3))]
        if has(0.06):
            s["not"] = sub()
        if has(0.07):
            s["if"] = sub()
            for k in ("then", "else"):
                if has(0.6):
                    s[k] = sub()
        for k in ("unevaluatedProperties", "unevaluatedItems"):
            if has(0.07):
                s[k] = sub()
        if self.defs and has(0.12):
            s["$ref"] = "#/$defs/" + r.choice(list(self.defs)) if not self.anchor or has(0.5) else "#x"
        if has(0.03):
            s["format"] = r.choice(["email", "date", "uuid"])
        return s

    def root(self):
        r = self.rng
        self.defs, defined = None, {}
        for i in range(r.randint(0, 2)):
            defined["d%d" % i] = self.schema(2)
        if defined and r.random() < 0.5:
            first = next(iter(defined))
            defined[first] = {"$anchor": "x", **(defined[first] if isinstance(defined[first], dict) else {"not": not defined[first]})}
            self.anchor = True
        self.defs = defined
        root = self.schema(0)
        if not isinstance(root, dict):
            root = {"not": root}
        if defined:
            root["$defs"] = defined
        return root


def dynamic(rng):
    """Two resources: a base with a dynamic anchor its members refer to, and an extension that replaces the anchor."""
    leaf = rng.choice([{"type": "string"}, {"type": "integer"}, {"maxLength": 1}, {"minimum": 1}, {}])
    base = {"$id": "https://x/base", "$dynamicAnchor": "n", "type": ["object", "string", "integer"],
            "properties": {"kid": {"$dynamicRef": "#n"}}, "additionalProperties": rng.choice([True, False, {"$dynamicRef": "#n"}])}
    ext = {"$id": "https://x/ext", "$dynamicAnchor": "n", "$ref": "base", "$defs": {"base": base}}
    ext.update(rng.choice([{}, {"unevaluatedProperties": False}, {"properties": {"kid": leaf}}]))
    if rng.random() < 0.5:
        return ext
    base = dict(base, **({"unevaluatedProperties": False} if rng.random() < 0.5 else {}))
    return {"$id": "https://x/root", "$ref": "base", "$defs": {"base": base}}


def instances(g, count):
    return [g.value() for _ in range(count)]


def verdicts(schema, texts):
    registry = referencing.Registry().with_resource("https://x/none", referencing.Resource.from_contents(True, referencing.jsonschema.DRAFT202012))
    validator = jsonschema.Draft202012Validator(schema, registry=registry)
    return "".join("V" if validator.is_valid(json.loads(t)) else "I" for t in texts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("probe")
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--cases", type=int, default=2000)
    ap.add_argument("--instances", type=int, default=8)
    args = ap.parse_args()
    total = checks = differ = unoracle = 0
    unbound = {}
    for seed in range(1, args.seeds + 1):
        rng = random.Random(seed)
        cases = []
        for _ in range(args.cases):
            g = Gen(rng)
            s = dynamic(rng) if rng.random() < 0.1 else g.root()
            cases.append((s, [json.dumps(v) for v in instances(g, args.instances)]))
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as f:
            f.write("".join(json.dumps({"schema": json.dumps(s), "instances": t}) + "\n" for s, t in cases))
            f.flush()
            run = subprocess.run([args.probe, f.name], capture_output=True, text=True)
        if run.returncode:
            sys.exit(f"the probe stopped with {run.returncode} on seed {seed}: {run.stderr[-600:]}")
        for (s, texts), mine in zip(cases, run.stdout.splitlines()):
            total += 1
            try:
                want = verdicts(s, texts)
            except Exception:
                unoracle += 1
                continue
            if mine.startswith("U"):
                keyword = re.search(r'text = "([^"]*)"', mine)
                unbound[keyword[1] if keyword else mine] = unbound.get(keyword[1] if keyword else mine, 0) + 1
                continue
            got = mine.replace(" ", "")
            checks += len(texts)
            if want != got:
                differ += 1
                if differ <= 10:
                    bad = [t for t, a, b in zip(texts, want, got) if a != b][:2]
                    print(f"seed {seed}: jsonschema {want!r}, probe {mine!r}\n  schema {json.dumps(s)}\n  differing instances {bad}")
    print(f"{total} schemas, {checks} verdicts, {differ} schemas differ, {unoracle} that jsonschema cannot compile, {sum(unbound.values())} not bound {unbound}")
    sys.exit(1 if differ else 0)


main()
