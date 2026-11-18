"""The msgspec arm of the model lane: a `Struct` whose members carry `Meta` constraints, read by
`msgspec.json.Decoder(type).decode` and written by `Encoder.encode`. A decode stops at the first rule a record breaks, so
the arm has no `load` row that lists every failure."""

from typing import Annotated

import msgspec
from msgspec import Meta, Struct

import arm

Count = Annotated[int, Meta(ge=0)]
Created = r"^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000 [0-9]{4}$"


def string(min_length=None, max_length=None, pattern=None):
    return Annotated[str, Meta(min_length=min_length, max_length=max_length, pattern=pattern)]


class LogRecord(Struct, kw_only=True):
    ts: string(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$")
    level: string(pattern=r"^(trace|debug|info|warn|error)$")
    service: string(1, 16)
    msg: string(1, 200)
    status: Annotated[int, Meta(ge=100, le=599)]
    bytes: Count
    duration_ms: Annotated[float, Meta(ge=0, le=60000)]
    id: string(pattern=r"^req-[0-9a-f]{8}$")
    region: string(max_length=16) = "local"


class Metadata(Struct, kw_only=True):
    result_type: string(pattern=r"^(recent|popular|mixed)$")
    iso_language_code: string(pattern=r"^[a-z]{2,3}$")


class User(Struct, kw_only=True):
    id: Annotated[int, Meta(ge=1)]
    id_str: string(pattern=r"^[0-9]{1,19}$")
    name: string(1, 50)
    screen_name: string(pattern=r"^[A-Za-z0-9_]{1,15}$")
    location: string(max_length=100)
    description: string(max_length=200)
    created_at: string(pattern=Created)
    followers_count: Count
    friends_count: Count
    listed_count: Count
    favourites_count: Count
    statuses_count: Count
    lang: string(pattern=r"^[a-z]{2}(-[a-z]{2})?$")
    verified: bool
    protected: bool


class Tweet(Struct, kw_only=True):
    metadata: Metadata
    created_at: string(pattern=Created)
    id: Annotated[int, Meta(ge=1)]
    id_str: string(pattern=r"^[0-9]{1,19}$")
    text: string(1, 140)
    source: string(1, 200)
    truncated: bool
    retweet_count: Count
    favorite_count: Count
    lang: string(pattern=r"^[a-z]{2,3}$")
    user: User
    reviewed: bool = False


def shape(cls, tally, spelled=lambda text: text):
    decode = msgspec.json.Decoder(cls).decode
    encode = msgspec.json.Encoder().encode

    def first(lines):
        models, refused = [], 0
        for line in lines:
            try:
                models.append(decode(line))
            except msgspec.ValidationError:
                refused += 1
        return models, refused

    def dump(models):
        return [encode(m) for m in models]

    return arm.Shape(tally, None, first, dump, spelled)


arm.main({"logs": shape(LogRecord, "bytes", arm.logs_spelled), "twitter": shape(Tweet, "retweet_count")})
