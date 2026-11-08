// The fixtures' types for the typed read and write lanes, and the map and string types they hold. A bin includes the
// file with `#[path]`.
#![allow(dead_code)]
use serde::de::{MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;
use std::hash::Hash;
use std::marker::PhantomData;

// A JSON object as a hash map, whose `Serialize` sorts the keys in the timed write, as a map write in stury does.
pub struct SortedMap<K, T>(pub HashMap<K, T>);

impl<K: Serialize + Ord + Hash, T: Serialize> Serialize for SortedMap<K, T> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut keys: Vec<&K> = self.0.keys().collect();
        keys.sort_unstable();
        let mut m = s.serialize_map(Some(keys.len()))?;
        for k in keys {
            m.serialize_entry(k, &self.0[k])?;
        }
        m.end()
    }
}

impl<'de, K: Deserialize<'de> + Hash + Eq, T: Deserialize<'de>> Deserialize<'de> for SortedMap<K, T> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V<K, T>(PhantomData<(K, T)>);
        impl<'de, K: Deserialize<'de> + Hash + Eq, T: Deserialize<'de>> Visitor<'de> for V<K, T> {
            type Value = SortedMap<K, T>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut m: A) -> Result<SortedMap<K, T>, A::Error> {
                let mut map = HashMap::with_capacity(m.size_hint().unwrap_or(0));
                while let Some((k, v)) = m.next_entry()? {
                    map.insert(k, v);
                }
                Ok(SortedMap(map))
            }
        }
        d.deserialize_map(V(PhantomData))
    }
}

// A string borrowed from the input when the reader hands it over undecoded, and decoded into bytes of its own when not.
#[derive(PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Text<'a>(pub Cow<'a, str>);

impl Serialize for Text<'_> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.0)
    }
}

impl<'de: 'a, 'a> Deserialize<'de> for Text<'a> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Text<'de>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a string")
            }
            fn visit_borrowed_str<E>(self, v: &'de str) -> Result<Text<'de>, E> {
                Ok(Text(Cow::Borrowed(v)))
            }
            fn visit_str<E>(self, v: &str) -> Result<Text<'de>, E> {
                Ok(Text(Cow::Owned(v.to_owned())))
            }
            fn visit_string<E>(self, v: String) -> Result<Text<'de>, E> {
                Ok(Text(Cow::Owned(v)))
            }
        }
        d.deserialize_str(V)
    }
}

// The fixtures' types, with the fields the typed read keeps. `S` is a string: `String` copies it, and `Text` borrows it
// from the input when it has no escape.
#[derive(Serialize, Deserialize)]
pub struct LogRecord<S = String> {
    pub ts: S,
    pub level: S,
    pub service: S,
    pub msg: S,
    pub status: i64,
    pub bytes: i64,
    pub duration_ms: f64,
    pub id: S,
}

#[derive(Serialize, Deserialize)]
pub struct Logs<S = String> {
    pub logs: Vec<LogRecord<S>>,
}

#[derive(Serialize, Deserialize)]
pub struct TweetMetadata<S = String> {
    pub result_type: S,
    pub iso_language_code: S,
}

#[derive(Serialize, Deserialize)]
pub struct TwitterUser<S = String> {
    pub id: i64,
    pub id_str: S,
    pub name: S,
    pub screen_name: S,
    pub location: S,
    pub description: S,
    pub created_at: S,
    pub followers_count: i64,
    pub friends_count: i64,
    pub listed_count: i64,
    pub favourites_count: i64,
    pub statuses_count: i64,
    pub lang: S,
    pub verified: bool,
    pub protected: bool,
}

#[derive(Serialize, Deserialize)]
pub struct Tweet<S = String> {
    pub metadata: TweetMetadata<S>,
    pub created_at: S,
    pub id: i64,
    pub id_str: S,
    pub text: S,
    pub source: S,
    pub truncated: bool,
    pub retweet_count: i64,
    pub favorite_count: i64,
    pub lang: S,
    pub user: TwitterUser<S>,
}

#[derive(Serialize, Deserialize)]
pub struct Twitter<S = String> {
    pub statuses: Vec<Tweet<S>>,
}

#[derive(Serialize, Deserialize)]
#[allow(non_snake_case)]
pub struct CitmEvent<S = String> {
    pub id: i64,
    pub name: S,
    pub subTopicIds: Vec<i64>,
    pub topicIds: Vec<i64>,
}

#[derive(Serialize, Deserialize)]
#[allow(non_snake_case)]
pub struct CitmPrice {
    pub amount: i64,
    pub audienceSubCategoryId: i64,
    pub seatCategoryId: i64,
}

#[derive(Serialize, Deserialize)]
#[allow(non_snake_case)]
pub struct CitmPerf<S = String> {
    pub eventId: i64,
    pub id: i64,
    pub start: i64,
    pub venueCode: S,
    pub prices: Vec<CitmPrice>,
}

#[derive(Serialize, Deserialize)]
#[serde(bound(serialize = "S: Serialize + Ord + Hash", deserialize = "S: Deserialize<'de> + Hash + Eq"))]
#[allow(non_snake_case)]
pub struct Citm<S = String> {
    pub areaNames: SortedMap<S, S>,
    pub blockNames: SortedMap<S, S>,
    pub events: SortedMap<S, CitmEvent<S>>,
    pub performances: Vec<CitmPerf<S>>,
    pub topicSubTopics: SortedMap<S, Vec<i64>>,
    pub venueNames: SortedMap<S, S>,
}

#[derive(Serialize, Deserialize)]
pub struct CanadaGeo {
    pub r#type: String,
    pub coordinates: Vec<Vec<[f64; 2]>>,
}

#[derive(Serialize, Deserialize)]
pub struct CanadaFeat {
    pub r#type: String,
    pub geometry: CanadaGeo,
}

#[derive(Serialize, Deserialize)]
pub struct Canada {
    pub r#type: String,
    pub features: Vec<CanadaFeat>,
}

#[derive(Serialize, Deserialize)]
pub struct NestedB {
    pub c: i64,
}

#[derive(Serialize, Deserialize)]
pub struct NestedInner {
    pub a: Vec<f64>,
    pub b: NestedB,
}

#[derive(Serialize, Deserialize)]
pub struct NestedRecord {
    pub id: i64,
    pub name: String,
    pub tags: Vec<i64>,
    pub nested: NestedInner,
    pub ok: bool,
}
