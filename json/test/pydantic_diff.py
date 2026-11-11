#!/usr/bin/env python3
"""Compares the errors model.load gives each value with pydantic 2 in strict mode.

The models of json/test/oracle/main.odin are declared here in pydantic. Generated bodies, with unknown members and
repeated keys, go through both, and the first code each refuses a pointer with must be the same, but where `explained`
names the difference. pydantic keeps the last of a repeated key and judges only it, while a collecting load judges each
occurrence, so a body that repeats a key is compared only by the oracle's `refuse` run, which must refuse it and must
give every other body the errors of its `last` run. Usage: pydantic_diff.py ORACLE_BINARY [--seed=N] [--count=N]
"""
import json
import random
import subprocess
import sys
import tempfile
from typing import Annotated, Dict, List, Literal, Optional, Tuple, Union, get_args, get_origin

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, ValidationError


class TypeRange:
    """Marks the bounds of an integer as its Odin type's range, which stury refuses as `Out_Of_Range`, not as a rule."""


class Address(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    street: str
    floor: Annotated[int, Field(ge=-128, le=127), TypeRange()]


class Cat(BaseModel):
    model_config = ConfigDict(strict=True)
    type: Literal["Cat"]
    lives: Annotated[int, Field(ge=0, le=9)]


class Dog(BaseModel):
    model_config = ConfigDict(strict=True)
    type: Literal["Dog"]
    bark: Annotated[str, StringConstraints(min_length=1)]


class Profile(BaseModel):
    model_config = ConfigDict(strict=True)
    name: Annotated[str, StringConstraints(min_length=1, max_length=8)]
    age: Annotated[int, Field(ge=0, le=150)]
    score: Annotated[float, Field(ge=0, le=1)]
    step: Annotated[int, Field(multiple_of=5)]
    mode: Literal["Fast", "Slow"]
    pair: Tuple[int, int]
    nick: Optional[Annotated[str, StringConstraints(min_length=2)]]
    tags: Annotated[List[str], Field(max_length=2)] = []
    home: Address
    level: int = 7
    count: Annotated[Dict[str, int], Field(max_length=2)] = {}
    pet: Optional[Annotated[Union[Cat, Dog], Field(discriminator="type")]] = None


def annotation_at(loc):
    """The declared type and metadata of the member `loc` names, or (None, []) for an element, a map value or a tag."""
    model, found = Profile, (None, [])
    for step in loc:
        if model is None or not isinstance(step, str) or step not in model.model_fields:
            return None, []
        info = model.model_fields[step]
        found = (info.annotation, info.metadata)
        inner = info.annotation
        if get_origin(inner) is Union:
            inner = next((a for a in get_args(inner) if a is not type(None)), inner)
        model = inner if isinstance(inner, type) and issubclass(inner, BaseModel) else None
    return found


def pointer(loc):
    return "".join("/" + str(step).replace("~", "~0").replace("/", "~1") for step in loc)


def refusal_of(err):
    """The (pointer, kind) stury gives the refusal err of pydantic, by pydantic's code and the declared type."""
    kind, loc = err["type"], tuple(err["loc"])
    # A discriminated union's errors name the arm by its tag, which stury's path does not hold.
    if len(loc) > 1 and loc[0] == "pet" and loc[1] in ("Cat", "Dog"):
        loc = loc[:1] + loc[2:]
    annotation, metadata = annotation_at(loc)
    fixed = get_origin(annotation) is tuple
    if kind == "missing" and len(loc) > 1 and get_origin(annotation_at(loc[:-1])[0]) is tuple:
        return pointer(loc[:-1]), "Wrong_Length"
    if kind == "missing":
        return pointer(loc), "Missing_Field"
    if kind == "union_tag_not_found":
        return pointer(loc), "Missing_Tag"
    if kind == "extra_forbidden":
        return pointer(loc), "Unknown_Field"
    if kind in ("too_short", "too_long") and fixed:
        return pointer(loc), "Wrong_Length"
    if kind in ("string_too_short", "too_short"):
        return pointer(loc), "Too_Short"
    if kind == "string_too_long":
        return pointer(loc), "Too_Long"
    if kind == "too_long":
        return pointer(loc), "Too_Many"
    if kind in ("greater_than_equal", "less_than_equal"):
        if any(isinstance(m, TypeRange) for m in metadata):
            return pointer(loc), "Out_Of_Range"
        return pointer(loc), "Below_Minimum" if kind == "greater_than_equal" else "Above_Maximum"
    if kind == "multiple_of":
        return pointer(loc), "Not_Multiple"
    if kind == "literal_error":
        return pointer(loc), "Not_A_Member" if isinstance(err["input"], str) else "Wrong_Kind"
    if kind.endswith("_type") or kind in ("model_type", "model_attributes_type"):
        return pointer(loc), "Wrong_Kind"
    return pointer(loc), "?" + kind


def pydantic_errors(body):
    """The pointer to the code of the one error pydantic gives each value."""
    try:
        Profile.model_validate_json(body, strict=True)
    except ValidationError as e:
        found = {}
        for err in e.errors():
            at, code = refusal_of(err)
            found.setdefault(at, code)
        return found
    return {}


def stury_errors(line):
    """The pointer to the first kind stury reports at it, and the pointers it reports more at."""
    first, more = {}, set()
    if line.startswith("fatal "):
        return {"": "fatal " + line[6:]}, more
    for item in line.split("\t") if line else []:
        at, code = item.split(" ")
        if code == "Wrong_Length" and at.startswith("/pair/"):
            at = "/pair"
        if at in first:
            more.add(at)
        else:
            first[at] = code
    return first, more


INT_POINTERS = ("/age", "/step", "/home/floor", "/pair/0", "/pair/1")


def repeats(text):
    """Whether an object of the body repeats a key."""
    found = []

    def check(pairs):
        names = [k for k, _ in pairs]
        found.append(len(names) != len(set(names)))
        return dict(pairs)

    json.loads(text, object_pairs_hook=check)
    return any(found)


def explained(at, body_value, got, want):
    """The expected difference at pointer `at`, or None. Decision 2: an integer field takes 1.0 and 1e2, a float with an
    integral value. Decision 3 compares a float bound exactly, so a float one ulp past a bound is refused by both, and
    shows nowhere here. Decision 6 is `more`: stury reports every failing rule of a value."""
    if at in INT_POINTERS and got is None and want == "Wrong_Kind" and isinstance(body_value, float) and body_value.is_integer():
        return "decision 2"
    return None


NAMES = ['"ada"', '""', '"abcdefghijk"', '"é' + "é" * 8 + '"', '"😀😀😀😀😀"', "5", "null", "true", "[]"]
AGES = ["36", "0", "150", "-1", "151", "1.5", '"x"', "null", "true", "9007199254740993", "-0", "1e2", "10.0"]
SCORES = ["0.5", "0", "1", "2", "-0.5", "1.0", '"x"', "null", "5E-1", "1e0", "-0.0", "1.0000000000000002"]
STEPS = ["10", "0", "11", "-5", "10.5", '"x"', "null", "1e1", "10.0", "-0"]
MODES = ['"Fast"', '"Slow"', '"Nope"', "1", "null", "[]"]
PAIRS = ["[1,2]", "[1]", "[1,2,3]", "[]", '"x"', '["a",2]', "[1,null]", "null"]
NICKS = ["null", '"cc"', '"c"', '""', "5", "[]"]
TAGS = ['["a"]', "[]", '["a","b","c"]', "1", "[null]", '["a",1]', "null"]
HOMES = [
    '{"street":"x","floor":3}',
    '{"street":"x","floor":300}',
    '{"street":"x"}',
    '{"floor":3}',
    '{"street":"x","floor":3,"zip":1}',
    '{"street":"x","floor":3,"floor":4}',
    '{"street":"x","floor":-129}',
    '{"street":5,"floor":"y"}',
    "5",
    "null",
    "{}",
]
FIELDS = [
    ("name", NAMES), ("age", AGES), ("score", SCORES), ("step", STEPS), ("mode", MODES),
    ("pair", PAIRS), ("nick", NICKS), ("tags", TAGS), ("home", HOMES),
]
IDS = ["5", '"x"', "null", "[1,{}]"]
LEVELS = ["0", "-3", "1.5", '"x"', "null"]
COUNTS = ['{"a":1}', "{}", '{"a":1,"b":2,"c":3}', '{"a":"x"}', '{"a":null}', "[]", "null"]
PETS = [
    '{"type":"Cat","lives":3}',
    '{"type":"Cat","lives":10}',
    '{"type":"Cat","bark":"w"}',
    '{"type":"Dog","bark":"w"}',
    '{"type":"Dog","bark":""}',
    '{"lives":3}',
    "null",
    "5",
]
FIELDS += [("id", IDS), ("level", LEVELS), ("count", COUNTS), ("pet", PETS)]
EXTRAS = [("zzz", "1"), ("zzz", "[]"), ("other", '{"a":1}')]


def body(rng):
    if rng.randrange(100) < 3:
        return rng.choice(["[]", "5", "null", '"x"', "{}"])
    members = []
    for name, values in FIELDS:
        if rng.randrange(100) < 88:
            members.append((name if rng.randrange(20) else "".join("\\u%04x" % ord(c) for c in name), rng.choice(values)))
            if rng.randrange(100) < 3:
                members.append((name, rng.choice(values)))
    if rng.randrange(100) < 15:
        members.append(rng.choice(EXTRAS))
    rng.shuffle(members)
    return "{" + ",".join('"%s":%s' % m for m in members) + "}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    if len(args) != 1:
        sys.exit(__doc__)
    rng = random.Random(int(opts.get("seed", 1)))
    bodies = [body(rng) for _ in range(int(opts.get("count", 3000)))]
    for b in bodies:
        json.loads(b)
    with tempfile.NamedTemporaryFile("w", suffix=".ndjson") as f:
        f.write("\n".join(bodies) + "\n")
        f.flush()
        runs = {mode: subprocess.run([args[0], f.name, mode], capture_output=True, text=True) for mode in ("last", "refuse")}
    outputs = {}
    for mode, ran in runs.items():
        if ran.returncode != 0:
            sys.exit("oracle failed: " + ran.stderr)
        outputs[mode] = ran.stdout.split("\n")[:-1]
        if len(outputs[mode]) != len(bodies):
            sys.exit("oracle gave %d lines for %d bodies" % (len(outputs[mode]), len(bodies)))
    bad, expected, more_count, skipped, refused = 0, {}, 0, 0, 0
    for b, line, strict in zip(bodies, outputs["last"], outputs["refuse"]):
        if repeats(b):
            skipped += 1
            if strict == "fatal Duplicate_Key":
                refused += 1
            else:
                bad += 1
                print("repeat  ", b)
                print("  refuse  ", strict)
            continue
        if strict != line:
            bad += 1
            print("refuse  ", b)
            print("  last    ", line)
            print("  refuse  ", strict)
            continue
        want = pydantic_errors(b)
        got, more = stury_errors(line)
        more_count += len(more)
        parsed = json.loads(b)
        differ = False
        for at in set(got) | set(want):
            if got.get(at) == want.get(at):
                continue
            value = parsed
            try:
                for step in at.split("/")[1:]:
                    value = value[int(step)] if isinstance(value, list) else value[step]
            except (KeyError, IndexError, TypeError, ValueError):
                value = None
            why = explained(at, value, got.get(at), want.get(at))
            if why:
                expected[why] = expected.get(why, 0) + 1
            else:
                differ = True
        if differ:
            bad += 1
            if bad <= 15:
                print("body    ", b)
                print("  stury   ", sorted(got.items()))
                print("  pydantic", sorted(want.items()))
    print("%d bodies, %d differ unexpectedly, expected: %s, values with more than one failing rule: %d, bodies with a repeated key refused: %d of %d" % (len(bodies), bad, expected, more_count, refused, skipped))
    sys.exit(1 if bad else 0)


main()
