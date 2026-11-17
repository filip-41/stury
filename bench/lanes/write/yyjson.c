// `write-yyjson typed|doc FILE [pretty]`: yyjson's writer. `doc` writes the parsed document, `typed` builds a mutable
// document from C structs read from the fixture and writes that.
#include <stdbool.h>
#include <yyjson.h>

#include "timing.h"

// Every call writes into one buffer, allocated once and reused. A document's GB/s counts the source's bytes. A typed
// lane's counts the output's, and its clock includes building the mutable document, since yyjson writes no struct
// without one. Strings are borrowed, never copied. Loading the fixture into the structs is outside the clock, and so
// is freeing each call's document.

typedef struct {
	const char *p;
	size_t n;
} str;

typedef struct {
	int64_t *v;
	size_t n;
} int_list;

// An object with any keys, kept as pairs.
typedef struct {
	str k;
	union {
		str s;
		int_list l;
		void *p;
	} v;
} pair;

static str str_of(yyjson_val *o, const char *k) {
	yyjson_val *v = yyjson_obj_get(o, k);
	return (str){yyjson_get_str(v), yyjson_get_len(v)};
}
static int64_t int_of(yyjson_val *o, const char *k) { return yyjson_get_sint(yyjson_obj_get(o, k)); }
static double real_of(yyjson_val *o, const char *k) { return yyjson_get_num(yyjson_obj_get(o, k)); }
static bool bool_of(yyjson_val *o, const char *k) { return yyjson_get_bool(yyjson_obj_get(o, k)); }

// Bump allocation for the loaded structs. The region is reserved once and only the pages it uses are touched.
#define POOL_BYTES ((size_t)256 << 20)
static char *pool;
static size_t pool_at;

static void *pool_alloc(size_t n) {
	n = (n + 15) & ~(size_t)15;
	if (!pool) pool = malloc(POOL_BYTES);
	if (!pool || pool_at + n > POOL_BYTES) {
		fprintf(stderr, "write-yyjson: write pool exhausted\n");
		exit(1);
	}
	void *p = pool + pool_at;
	pool_at += n;
	return p;
}

static int_list ints_of(yyjson_val *a) {
	int_list l = {NULL, yyjson_arr_size(a)};
	l.v = pool_alloc(l.n * sizeof *l.v);
	size_t i, m;
	yyjson_val *e;
	yyjson_arr_foreach(a, i, m, e) l.v[i] = yyjson_get_sint(e);
	return l;
}

static pair *pairs_of(yyjson_val *o, size_t *n) {
	*n = yyjson_obj_size(o);
	pair *v = pool_alloc(*n * sizeof *v);
	size_t i, m;
	yyjson_val *k, *val;
	yyjson_obj_foreach(o, i, m, k, val) {
		v[i].k = (str){yyjson_get_str(k), yyjson_get_len(k)};
		v[i].v.p = val;
	}
	return v;
}

// A map has no order; a hash map's iteration starts from an arbitrary permutation. A map's pairs are shuffled once
// outside the clock, and each write sorts their indexes, as a map's write does.
static uint64_t map_rng = 0x9e3779b97f4a7c15ULL;
static uint64_t map_rand(void) {
	map_rng ^= map_rng << 13;
	map_rng ^= map_rng >> 7;
	map_rng ^= map_rng << 17;
	return map_rng;
}

static void shuffle(pair *v, size_t n) {
	for (size_t i = n; i > 1; i--) {
		size_t j = map_rand() % i;
		pair t = v[i - 1];
		v[i - 1] = v[j];
		v[j] = t;
	}
}

static const pair *sorted_pairs;

static int key_cmp(const void *a, const void *b) {
	const pair *x = &sorted_pairs[*(const size_t *)a], *y = &sorted_pairs[*(const size_t *)b];
	size_t n = x->k.n < y->k.n ? x->k.n : y->k.n;
	int c = memcmp(x->k.p, y->k.p, n);
	if (c) return c;
	return (x->k.n > y->k.n) - (x->k.n < y->k.n);
}

// The indexes of `v` in key order, for the caller to free.
static size_t *sorted_order(const pair *v, size_t n) {
	size_t *idx = malloc((n ? n : 1) * sizeof *idx);
	if (!idx) abort();
	for (size_t i = 0; i < n; i++) idx[i] = i;
	sorted_pairs = v;
	qsort(idx, n, sizeof *idx, key_cmp);
	return idx;
}

static pair *string_pairs(yyjson_val *o, size_t *n) {
	pair *v = pairs_of(o, n);
	for (size_t i = 0; i < *n; i++) {
		yyjson_val *s = v[i].v.p;
		v[i].v.s = (str){yyjson_get_str(s), yyjson_get_len(s)};
	}
	return v;
}

static void add_str(yyjson_mut_doc *m, yyjson_mut_val *o, const char *k, str s) { yyjson_mut_obj_add_strn(m, o, k, s.p, s.n); }

static yyjson_mut_val *key_of(yyjson_mut_doc *m, str k) { return yyjson_mut_strn(m, k.p, k.n); }

static yyjson_mut_val *add_ints(yyjson_mut_doc *m, yyjson_mut_val *arr, int_list l) {
	for (size_t i = 0; i < l.n; i++) yyjson_mut_arr_add_sint(m, arr, l.v[i]);
	return arr;
}

static void add_string_map(yyjson_mut_doc *m, yyjson_mut_val *root, const char *name, const pair *v, size_t n) {
	yyjson_mut_val *o = yyjson_mut_obj_add_obj(m, root, name);
	size_t *idx = sorted_order(v, n);
	for (size_t i = 0; i < n; i++) {
		const pair *e = &v[idx[i]];
		yyjson_mut_obj_add(o, key_of(m, e->k), yyjson_mut_strn(m, e->v.s.p, e->v.s.n));
	}
	free(idx);
}

// logs.json
typedef struct {
	str ts, level, service, msg, id;
	int64_t status, bytes;
	double duration_ms;
} log_record;
typedef struct {
	log_record *v;
	size_t n;
} logs;

static const void *load_logs(yyjson_val *root) {
	yyjson_val *a = yyjson_obj_get(root, "logs"), *e;
	logs *l = pool_alloc(sizeof *l);
	l->n = yyjson_arr_size(a);
	l->v = pool_alloc(l->n * sizeof *l->v);
	size_t i, m;
	yyjson_arr_foreach(a, i, m, e) {
		log_record *r = &l->v[i];
		r->ts = str_of(e, "ts");
		r->level = str_of(e, "level");
		r->service = str_of(e, "service");
		r->msg = str_of(e, "msg");
		r->status = int_of(e, "status");
		r->bytes = int_of(e, "bytes");
		r->duration_ms = real_of(e, "duration_ms");
		r->id = str_of(e, "id");
	}
	return l;
}

static yyjson_mut_val *build_logs(yyjson_mut_doc *m, const void *p) {
	const logs *l = p;
	yyjson_mut_val *root = yyjson_mut_obj(m), *a = yyjson_mut_obj_add_arr(m, root, "logs");
	for (size_t i = 0; i < l->n; i++) {
		const log_record *r = &l->v[i];
		yyjson_mut_val *o = yyjson_mut_arr_add_obj(m, a);
		add_str(m, o, "ts", r->ts);
		add_str(m, o, "level", r->level);
		add_str(m, o, "service", r->service);
		add_str(m, o, "msg", r->msg);
		yyjson_mut_obj_add_sint(m, o, "status", r->status);
		yyjson_mut_obj_add_sint(m, o, "bytes", r->bytes);
		yyjson_mut_obj_add_real(m, o, "duration_ms", r->duration_ms);
		add_str(m, o, "id", r->id);
	}
	return root;
}

// twitter.json
typedef struct {
	int64_t id, followers_count, friends_count, listed_count, favourites_count, statuses_count;
	str id_str, name, screen_name, location, description, created_at, lang;
	bool verified, is_protected;
} twitter_user;
typedef struct {
	str result_type, iso_language_code, created_at, id_str, text, source, lang;
	int64_t id, retweet_count, favorite_count;
	bool truncated;
	twitter_user user;
} tweet;
typedef struct {
	tweet *v;
	size_t n;
} twitter;

static const void *load_twitter(yyjson_val *root) {
	yyjson_val *a = yyjson_obj_get(root, "statuses"), *e;
	twitter *t = pool_alloc(sizeof *t);
	t->n = yyjson_arr_size(a);
	t->v = pool_alloc(t->n * sizeof *t->v);
	size_t i, m;
	yyjson_arr_foreach(a, i, m, e) {
		tweet *w = &t->v[i];
		yyjson_val *md = yyjson_obj_get(e, "metadata"), *u = yyjson_obj_get(e, "user");
		w->result_type = str_of(md, "result_type");
		w->iso_language_code = str_of(md, "iso_language_code");
		w->created_at = str_of(e, "created_at");
		w->id = int_of(e, "id");
		w->id_str = str_of(e, "id_str");
		w->text = str_of(e, "text");
		w->source = str_of(e, "source");
		w->truncated = bool_of(e, "truncated");
		w->retweet_count = int_of(e, "retweet_count");
		w->favorite_count = int_of(e, "favorite_count");
		w->lang = str_of(e, "lang");
		twitter_user *x = &w->user;
		x->id = int_of(u, "id");
		x->id_str = str_of(u, "id_str");
		x->name = str_of(u, "name");
		x->screen_name = str_of(u, "screen_name");
		x->location = str_of(u, "location");
		x->description = str_of(u, "description");
		x->created_at = str_of(u, "created_at");
		x->followers_count = int_of(u, "followers_count");
		x->friends_count = int_of(u, "friends_count");
		x->listed_count = int_of(u, "listed_count");
		x->favourites_count = int_of(u, "favourites_count");
		x->statuses_count = int_of(u, "statuses_count");
		x->lang = str_of(u, "lang");
		x->verified = bool_of(u, "verified");
		x->is_protected = bool_of(u, "protected");
	}
	return t;
}

static yyjson_mut_val *build_twitter(yyjson_mut_doc *m, const void *p) {
	const twitter *t = p;
	yyjson_mut_val *root = yyjson_mut_obj(m), *a = yyjson_mut_obj_add_arr(m, root, "statuses");
	for (size_t i = 0; i < t->n; i++) {
		const tweet *w = &t->v[i];
		yyjson_mut_val *o = yyjson_mut_arr_add_obj(m, a), *md = yyjson_mut_obj_add_obj(m, o, "metadata");
		add_str(m, md, "result_type", w->result_type);
		add_str(m, md, "iso_language_code", w->iso_language_code);
		add_str(m, o, "created_at", w->created_at);
		yyjson_mut_obj_add_sint(m, o, "id", w->id);
		add_str(m, o, "id_str", w->id_str);
		add_str(m, o, "text", w->text);
		add_str(m, o, "source", w->source);
		yyjson_mut_obj_add_bool(m, o, "truncated", w->truncated);
		yyjson_mut_obj_add_sint(m, o, "retweet_count", w->retweet_count);
		yyjson_mut_obj_add_sint(m, o, "favorite_count", w->favorite_count);
		add_str(m, o, "lang", w->lang);
		const twitter_user *x = &w->user;
		yyjson_mut_val *u = yyjson_mut_obj_add_obj(m, o, "user");
		yyjson_mut_obj_add_sint(m, u, "id", x->id);
		add_str(m, u, "id_str", x->id_str);
		add_str(m, u, "name", x->name);
		add_str(m, u, "screen_name", x->screen_name);
		add_str(m, u, "location", x->location);
		add_str(m, u, "description", x->description);
		add_str(m, u, "created_at", x->created_at);
		yyjson_mut_obj_add_sint(m, u, "followers_count", x->followers_count);
		yyjson_mut_obj_add_sint(m, u, "friends_count", x->friends_count);
		yyjson_mut_obj_add_sint(m, u, "listed_count", x->listed_count);
		yyjson_mut_obj_add_sint(m, u, "favourites_count", x->favourites_count);
		yyjson_mut_obj_add_sint(m, u, "statuses_count", x->statuses_count);
		add_str(m, u, "lang", x->lang);
		yyjson_mut_obj_add_bool(m, u, "verified", x->verified);
		yyjson_mut_obj_add_bool(m, u, "protected", x->is_protected);
	}
	return root;
}

// citm_catalog.json
typedef struct {
	int64_t id;
	str name;
	int_list sub, top;
} citm_event;
typedef struct {
	int64_t amount, audience, seat;
} citm_price;
typedef struct {
	int64_t event_id, id, start;
	str venue_code;
	citm_price *prices;
	size_t nprices;
} citm_perf;
typedef struct {
	pair *area, *block, *events, *topics, *venue;
	size_t narea, nblock, nevents, ntopics, nvenue;
	citm_perf *perfs;
	size_t nperfs;
} citm;

static const void *load_citm(yyjson_val *root) {
	citm *c = pool_alloc(sizeof *c);
	c->area = string_pairs(yyjson_obj_get(root, "areaNames"), &c->narea);
	c->block = string_pairs(yyjson_obj_get(root, "blockNames"), &c->nblock);
	c->venue = string_pairs(yyjson_obj_get(root, "venueNames"), &c->nvenue);
	c->events = pairs_of(yyjson_obj_get(root, "events"), &c->nevents);
	for (size_t i = 0; i < c->nevents; i++) {
		yyjson_val *o = c->events[i].v.p;
		citm_event *e = pool_alloc(sizeof *e);
		e->id = int_of(o, "id");
		e->name = str_of(o, "name");
		e->sub = ints_of(yyjson_obj_get(o, "subTopicIds"));
		e->top = ints_of(yyjson_obj_get(o, "topicIds"));
		c->events[i].v.p = e;
	}
	c->topics = pairs_of(yyjson_obj_get(root, "topicSubTopics"), &c->ntopics);
	for (size_t i = 0; i < c->ntopics; i++) c->topics[i].v.l = ints_of(c->topics[i].v.p);
	shuffle(c->area, c->narea);
	shuffle(c->block, c->nblock);
	shuffle(c->venue, c->nvenue);
	shuffle(c->events, c->nevents);
	shuffle(c->topics, c->ntopics);
	yyjson_val *a = yyjson_obj_get(root, "performances"), *e;
	c->nperfs = yyjson_arr_size(a);
	c->perfs = pool_alloc(c->nperfs * sizeof *c->perfs);
	size_t i, m;
	yyjson_arr_foreach(a, i, m, e) {
		citm_perf *f = &c->perfs[i];
		f->event_id = int_of(e, "eventId");
		f->id = int_of(e, "id");
		f->start = int_of(e, "start");
		f->venue_code = str_of(e, "venueCode");
		yyjson_val *pa = yyjson_obj_get(e, "prices"), *pe;
		f->nprices = yyjson_arr_size(pa);
		f->prices = pool_alloc(f->nprices * sizeof *f->prices);
		size_t j, jm;
		yyjson_arr_foreach(pa, j, jm, pe) {
			f->prices[j] = (citm_price){int_of(pe, "amount"), int_of(pe, "audienceSubCategoryId"), int_of(pe, "seatCategoryId")};
		}
	}
	return c;
}

static yyjson_mut_val *build_citm(yyjson_mut_doc *m, const void *p) {
	const citm *c = p;
	yyjson_mut_val *root = yyjson_mut_obj(m);
	add_string_map(m, root, "areaNames", c->area, c->narea);
	add_string_map(m, root, "blockNames", c->block, c->nblock);
	yyjson_mut_val *ev = yyjson_mut_obj_add_obj(m, root, "events");
	size_t *idx = sorted_order(c->events, c->nevents);
	for (size_t i = 0; i < c->nevents; i++) {
		const pair *p = &c->events[idx[i]];
		const citm_event *e = p->v.p;
		yyjson_mut_val *o = yyjson_mut_obj(m);
		yyjson_mut_obj_add(ev, key_of(m, p->k), o);
		yyjson_mut_obj_add_sint(m, o, "id", e->id);
		add_str(m, o, "name", e->name);
		add_ints(m, yyjson_mut_obj_add_arr(m, o, "subTopicIds"), e->sub);
		add_ints(m, yyjson_mut_obj_add_arr(m, o, "topicIds"), e->top);
	}
	free(idx);
	yyjson_mut_val *pf = yyjson_mut_obj_add_arr(m, root, "performances");
	for (size_t i = 0; i < c->nperfs; i++) {
		const citm_perf *f = &c->perfs[i];
		yyjson_mut_val *o = yyjson_mut_arr_add_obj(m, pf);
		yyjson_mut_obj_add_sint(m, o, "eventId", f->event_id);
		yyjson_mut_obj_add_sint(m, o, "id", f->id);
		yyjson_mut_obj_add_sint(m, o, "start", f->start);
		add_str(m, o, "venueCode", f->venue_code);
		yyjson_mut_val *pa = yyjson_mut_obj_add_arr(m, o, "prices");
		for (size_t j = 0; j < f->nprices; j++) {
			yyjson_mut_val *q = yyjson_mut_arr_add_obj(m, pa);
			yyjson_mut_obj_add_sint(m, q, "amount", f->prices[j].amount);
			yyjson_mut_obj_add_sint(m, q, "audienceSubCategoryId", f->prices[j].audience);
			yyjson_mut_obj_add_sint(m, q, "seatCategoryId", f->prices[j].seat);
		}
	}
	yyjson_mut_val *ts = yyjson_mut_obj_add_obj(m, root, "topicSubTopics");
	idx = sorted_order(c->topics, c->ntopics);
	for (size_t i = 0; i < c->ntopics; i++) {
		const pair *p = &c->topics[idx[i]];
		yyjson_mut_obj_add(ts, key_of(m, p->k), add_ints(m, yyjson_mut_arr(m), p->v.l));
	}
	free(idx);
	add_string_map(m, root, "venueNames", c->venue, c->nvenue);
	return root;
}

// canada.json: each feature's rings of [x, y] points, kept as flat doubles.
typedef struct {
	double *xy;
	size_t n;
} ring;
typedef struct {
	str type, geometry_type;
	ring *rings;
	size_t nrings;
} feature;
typedef struct {
	str type;
	feature *v;
	size_t n;
} canada;

static const void *load_canada(yyjson_val *root) {
	canada *c = pool_alloc(sizeof *c);
	c->type = str_of(root, "type");
	yyjson_val *a = yyjson_obj_get(root, "features"), *e;
	c->n = yyjson_arr_size(a);
	c->v = pool_alloc(c->n * sizeof *c->v);
	size_t i, m;
	yyjson_arr_foreach(a, i, m, e) {
		feature *f = &c->v[i];
		yyjson_val *g = yyjson_obj_get(e, "geometry"), *rs = yyjson_obj_get(g, "coordinates"), *r;
		f->type = str_of(e, "type");
		f->geometry_type = str_of(g, "type");
		f->nrings = yyjson_arr_size(rs);
		f->rings = pool_alloc(f->nrings * sizeof *f->rings);
		size_t j, jm;
		yyjson_arr_foreach(rs, j, jm, r) {
			ring *q = &f->rings[j];
			q->n = yyjson_arr_size(r);
			q->xy = pool_alloc(q->n * 2 * sizeof *q->xy);
			size_t k, km;
			yyjson_val *pt;
			yyjson_arr_foreach(r, k, km, pt) {
				q->xy[2 * k] = yyjson_get_num(yyjson_arr_get(pt, 0));
				q->xy[2 * k + 1] = yyjson_get_num(yyjson_arr_get(pt, 1));
			}
		}
	}
	return c;
}

static yyjson_mut_val *build_canada(yyjson_mut_doc *m, const void *p) {
	const canada *c = p;
	yyjson_mut_val *root = yyjson_mut_obj(m);
	add_str(m, root, "type", c->type);
	yyjson_mut_val *fs = yyjson_mut_obj_add_arr(m, root, "features");
	for (size_t i = 0; i < c->n; i++) {
		const feature *f = &c->v[i];
		yyjson_mut_val *o = yyjson_mut_arr_add_obj(m, fs);
		add_str(m, o, "type", f->type);
		yyjson_mut_val *g = yyjson_mut_obj_add_obj(m, o, "geometry");
		add_str(m, g, "type", f->geometry_type);
		yyjson_mut_val *rs = yyjson_mut_obj_add_arr(m, g, "coordinates");
		for (size_t j = 0; j < f->nrings; j++) {
			const ring *q = &f->rings[j];
			yyjson_mut_val *r = yyjson_mut_arr_add_arr(m, rs);
			for (size_t k = 0; k < q->n; k++) {
				yyjson_mut_val *pt = yyjson_mut_arr_add_arr(m, r);
				yyjson_mut_arr_add_real(m, pt, q->xy[2 * k]);
				yyjson_mut_arr_add_real(m, pt, q->xy[2 * k + 1]);
			}
		}
	}
	return root;
}

// nested.json
typedef struct {
	int64_t id, c;
	str name;
	int_list tags;
	double *a;
	size_t na;
	bool ok;
} nested_record;
typedef struct {
	nested_record *v;
	size_t n;
} nested;

static const void *load_nested(yyjson_val *root) {
	nested *d = pool_alloc(sizeof *d);
	d->n = yyjson_arr_size(root);
	d->v = pool_alloc(d->n * sizeof *d->v);
	size_t i, m;
	yyjson_val *e;
	yyjson_arr_foreach(root, i, m, e) {
		nested_record *r = &d->v[i];
		yyjson_val *inner = yyjson_obj_get(e, "nested"), *a = yyjson_obj_get(inner, "a"), *x;
		r->id = int_of(e, "id");
		r->name = str_of(e, "name");
		r->tags = ints_of(yyjson_obj_get(e, "tags"));
		r->na = yyjson_arr_size(a);
		r->a = pool_alloc(r->na * sizeof *r->a);
		size_t j, jm;
		yyjson_arr_foreach(a, j, jm, x) r->a[j] = yyjson_get_num(x);
		r->c = int_of(yyjson_obj_get(inner, "b"), "c");
		r->ok = bool_of(e, "ok");
	}
	return d;
}

static yyjson_mut_val *build_nested(yyjson_mut_doc *m, const void *p) {
	const nested *d = p;
	yyjson_mut_val *root = yyjson_mut_arr(m);
	for (size_t i = 0; i < d->n; i++) {
		const nested_record *r = &d->v[i];
		yyjson_mut_val *o = yyjson_mut_arr_add_obj(m, root);
		yyjson_mut_obj_add_sint(m, o, "id", r->id);
		add_str(m, o, "name", r->name);
		add_ints(m, yyjson_mut_obj_add_arr(m, o, "tags"), r->tags);
		yyjson_mut_val *inner = yyjson_mut_obj_add_obj(m, o, "nested"), *a = yyjson_mut_obj_add_arr(m, inner, "a");
		for (size_t j = 0; j < r->na; j++) yyjson_mut_arr_add_real(m, a, r->a[j]);
		yyjson_mut_obj_add_sint(m, yyjson_mut_obj_add_obj(m, inner, "b"), "c", r->c);
		yyjson_mut_obj_add_bool(m, o, "ok", r->ok);
	}
	return root;
}

// wide.json: one object of integers.
typedef struct {
	pair *v;
	size_t n;
} wide;

static const void *load_wide(yyjson_val *root) {
	wide *w = pool_alloc(sizeof *w);
	w->v = pairs_of(root, &w->n);
	shuffle(w->v, w->n);
	return w;
}

static yyjson_mut_val *build_wide(yyjson_mut_doc *m, const void *p) {
	const wide *w = p;
	yyjson_mut_val *root = yyjson_mut_obj(m);
	size_t *idx = sorted_order(w->v, w->n);
	for (size_t i = 0; i < w->n; i++) {
		const pair *e = &w->v[idx[i]];
		yyjson_mut_obj_add(root, key_of(m, e->k), yyjson_mut_sint(m, yyjson_get_sint(e->v.p)));
	}
	free(idx);
	return root;
}

typedef struct {
	const char *stem;
	const void *(*load)(yyjson_val *);
	yyjson_mut_val *(*build)(yyjson_mut_doc *, const void *);
} typed_lane;

static const typed_lane TYPED_LANES[] = {
	{"logs.json", load_logs, build_logs},
	{"twitter.json", load_twitter, build_twitter},
	{"citm_catalog.json", load_citm, build_citm},
	{"canada.json", load_canada, build_canada},
	{"nested.json", load_nested, build_nested},
	{"wide.json", load_wide, build_wide},
};

static const typed_lane *typed_lane_of(const char *path) {
	size_t pl = strlen(path);
	for (size_t i = 0; i < sizeof TYPED_LANES / sizeof *TYPED_LANES; i++) {
		size_t sl = strlen(TYPED_LANES[i].stem);
		if (pl >= sl && !strcmp(path + pl - sl, TYPED_LANES[i].stem)) return &TYPED_LANES[i];
	}
	return NULL;
}

// One timed write into `out`, `cap` bytes reused by every call. It returns the call's nanoseconds and the text's length
// in *len, 0 on a failure.
typedef long long (*write_once)(const void *, yyjson_write_flag, char *, size_t, size_t *);

static long long write_doc_once(const void *doc, yyjson_write_flag flg, char *out, size_t cap, size_t *len) {
	long long t = now_ns();
	*len = yyjson_write_buf(out, cap, (yyjson_doc *)doc, flg, NULL);
	keep(out);
	return now_ns() - t;
}

typedef struct {
	const typed_lane *lane;
	const void *data;
} typed_job;

static long long write_typed_once(const void *job, yyjson_write_flag flg, char *out, size_t cap, size_t *len) {
	const typed_job *j = job;
	long long t = now_ns();
	yyjson_mut_doc *m = yyjson_mut_doc_new(NULL);
	yyjson_mut_doc_set_root(m, j->lane->build(m, j->data));
	*len = yyjson_mut_write_buf(out, cap, m, flg, NULL);
	keep(out);
	long long el = now_ns() - t;
	yyjson_mut_doc_free(m);
	return el;
}

static int write_job(const char *path, bool typed, bool pretty) {
	long n;
	char *buf = load(path, &n);
	if (!buf) return 1;
	yyjson_read_err err;
	yyjson_doc *d = yyjson_read_opts(buf, n, 0, NULL, &err);
	if (!d) {
		fprintf(stderr, "yyjson read failed: code %u at byte %zu: %s\n", (unsigned)err.code, err.pos, err.msg);
		return 1;
	}
	yyjson_write_flag flg = pretty ? YYJSON_WRITE_PRETTY_TWO_SPACES : YYJSON_WRITE_NOFLAG;
	typed_job job = {typed_lane_of(path), NULL};
	if (typed) {
		if (!job.lane) {
			fprintf(stderr, "write-yyjson: no typed lane for %s\n", path);
			return 1;
		}
		job.data = job.lane->load(yyjson_doc_get_root(d));
	}
	write_once once = typed ? write_typed_once : write_doc_once;
	const void *arg = typed ? (const void *)&job : (const void *)d;
	long long ns[TIMED];
	size_t cap = 16 * (size_t)n + (64 << 10), len = 0;
	char *out = malloc(cap);
	if (!out) abort();
	for (int i = 0; i < WARMUP + TIMED; i++) {
		long long el = once(arg, flg, out, cap, &len);
		if (!len) {
			fprintf(stderr, "yyjson write failed\n");
			return 1;
		}
		if (i >= WARMUP) ns[i - WARMUP] = el;
	}
	report(typed ? len : (size_t)n, median(ns), fnv_bytes(CHECK_OFFSET, out, len), "out=%zu", len);
	free(out);
	return 0;
}

int main(int argc, char **argv) {
	bool typed = argc >= 3 && !strcmp(argv[1], "typed");
	if (argc < 3 || argc > 4 || (!typed && strcmp(argv[1], "doc"))) {
		fprintf(stderr, "usage: write-yyjson typed|doc FILE [pretty]\n");
		return 2;
	}
	return write_job(argv[2], typed, argc == 4 && !strcmp(argv[3], "pretty"));
}
