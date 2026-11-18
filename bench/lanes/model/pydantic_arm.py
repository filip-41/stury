"""The pydantic 2 arm of the model lane: `model_validate_json` of each record and `model_dump_json` to write it. A refused
record's `ValidationError` holds every failure, and `errors()` lists them."""

from typing import Annotated

from pydantic import BaseModel, Field, ValidationError

import arm

Count = Annotated[int, Field(ge=0)]
Created = r"^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000 [0-9]{4}$"


class LogRecord(BaseModel):
    ts: str = Field(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$")
    level: str = Field(pattern=r"^(trace|debug|info|warn|error)$")
    service: str = Field(min_length=1, max_length=16)
    msg: str = Field(min_length=1, max_length=200)
    status: int = Field(ge=100, le=599)
    bytes: Count
    duration_ms: float = Field(ge=0, le=60000)
    id: str = Field(pattern=r"^req-[0-9a-f]{8}$")
    region: str = Field("local", max_length=16)


class Metadata(BaseModel):
    result_type: str = Field(pattern=r"^(recent|popular|mixed)$")
    iso_language_code: str = Field(pattern=r"^[a-z]{2,3}$")


class User(BaseModel):
    id: int = Field(ge=1)
    id_str: str = Field(pattern=r"^[0-9]{1,19}$")
    name: str = Field(min_length=1, max_length=50)
    screen_name: str = Field(pattern=r"^[A-Za-z0-9_]{1,15}$")
    location: str = Field(max_length=100)
    description: str = Field(max_length=200)
    created_at: str = Field(pattern=Created)
    followers_count: Count
    friends_count: Count
    listed_count: Count
    favourites_count: Count
    statuses_count: Count
    lang: str = Field(pattern=r"^[a-z]{2}(-[a-z]{2})?$")
    verified: bool
    protected: bool


class Tweet(BaseModel):
    metadata: Metadata
    created_at: str = Field(pattern=Created)
    id: int = Field(ge=1)
    id_str: str = Field(pattern=r"^[0-9]{1,19}$")
    text: str = Field(min_length=1, max_length=140)
    source: str = Field(min_length=1, max_length=200)
    truncated: bool
    retweet_count: Count
    favorite_count: Count
    lang: str = Field(pattern=r"^[a-z]{2,3}$")
    user: User
    reviewed: bool = False


def shape(cls, tally, spelled=lambda text: text):
    validate = cls.model_validate_json

    def load(lines):
        models, failed = [], []
        for line in lines:
            try:
                models.append(validate(line))
            except ValidationError as e:
                failed.append([".".join(map(str, d["loc"])) for d in e.errors()])
        return models, failed

    def dump(models):
        return [m.model_dump_json() for m in models]

    return arm.Shape(tally, load, None, dump, spelled)


arm.main({"logs": shape(LogRecord, "bytes", arm.logs_spelled), "twitter": shape(Tweet, "retweet_count")})
