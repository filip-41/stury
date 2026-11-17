"""Compares the errors model.load gives each value with pydantic 2 in strict mode.

The models of main.odin are declared here in pydantic. Generated bodies go through both, and the first code each refuses
a pointer with must be the same, but where `explained` names the difference. A body that repeats a key is compared only
by the oracle's `refuse` run, since pydantic judges the last occurrence and a collecting load each.
"""
import json
import os
import random
import subprocess
from typing import Annotated, Dict, List, Literal, Optional, Tuple, Union, get_args, get_origin

import pytest
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, ValidationError

from capped import ROOT

COUNT = 3000

class Address(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    street: str
    floor: Annotated[int, Field(ge=-128, le=127)]


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
    annotation, _ = annotation_at(loc)
    fixed = get_origin(annotation) is tuple
    if kind == "missing" and len(loc) > 1 and get_origin(annotation_at(loc[:-1])[0]) is tuple:
        return pointer(loc[:-1]), "Too_Few"
    if kind == "missing":
        return pointer(loc), "Missing_Field"
    # A union takes no value of the kind or tag it was given, which stury reports as `No_Arm`, not as the arm's own fault.
    if loc == ("pet",) and (kind in ("union_tag_not_found", "union_tag_invalid", "model_type", "model_attributes_type", "dict_type")):
        return pointer(loc), "No_Arm"
    if kind == "union_tag_not_found":
        return pointer(loc), "Missing_Tag"
    if kind == "extra_forbidden":
        return pointer(loc), "Not_Allowed"
    if kind in ("too_short", "too_long") and fixed:
        return pointer(loc), "Too_Few" if kind == "too_short" else "Too_Many"
    if kind in ("string_too_short", "too_short"):
        return pointer(loc), "Too_Short"
    if kind == "string_too_long":
        return pointer(loc), "Too_Long"
    if kind == "too_long":
        return pointer(loc), "Too_Many"
    if kind in ("greater_than_equal", "less_than_equal"):
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
    shows nowhere here. Decision 6: stury reports every failing rule of a value."""
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


@pytest.fixture(scope="module")
def oracle(odin, tmp_path_factory):
    binary = str(tmp_path_factory.mktemp("model") / "model")
    subprocess.run([odin, "build", os.path.dirname(__file__), "-o:minimal", f"-out:{binary}"], cwd=ROOT, check=True)
    return binary


def test_model_load_errors_as_pydantic(oracle, seed, request, tmp_path):
    rng = random.Random(seed)
    bodies = [body(rng) for _ in range(request.config.getoption("--cases") or COUNT)]
    for b in bodies:
        json.loads(b)
    path = tmp_path / "bodies.ndjson"
    path.write_text("\n".join(bodies) + "\n")
    outputs = {}
    for mode in ("last", "refuse"):
        ran = subprocess.run([oracle, str(path), mode], capture_output=True, text=True)
        assert ran.returncode == 0, "oracle failed: " + ran.stderr
        outputs[mode] = ran.stdout.split("\n")[:-1]
        assert len(outputs[mode]) == len(bodies), "oracle gave %d lines for %d bodies" % (len(outputs[mode]), len(bodies))
    bad = []
    for b, line, strict in zip(bodies, outputs["last"], outputs["refuse"]):
        if repeats(b):
            if strict != "fatal Duplicate_Key":
                bad.append(f"repeat   {b}\n  refuse   {strict}")
            continue
        if strict != line:
            bad.append(f"refuse   {b}\n  last     {line}\n  refuse   {strict}")
            continue
        want = pydantic_errors(b)
        got, _ = stury_errors(line)
        parsed = json.loads(b)
        for at in set(got) | set(want):
            if got.get(at) == want.get(at):
                continue
            value = parsed
            try:
                for step in at.split("/")[1:]:
                    value = value[int(step)] if isinstance(value, list) else value[step]
            except (KeyError, IndexError, TypeError, ValueError):
                value = None
            if not explained(at, value, got.get(at), want.get(at)):
                bad.append(f"body     {b}\n  stury    {sorted(got.items())}\n  pydantic {sorted(want.items())}")
                break
    assert not bad, f"{len(bad)} of {len(bodies)} bodies differ unexpectedly:\n" + "\n".join(bad[:15])
