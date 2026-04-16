#include <ruby.h>
#include <ruby/encoding.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

#ifndef RB_UNLIKELY
#if defined(__GNUC__) || defined(__clang__)
#define RB_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define RB_UNLIKELY(x) (x)
#endif
#endif

#if defined(__GNUC__) || defined(__clang__)
#define SH_PREFETCH(p) __builtin_prefetch((const void *)(p), 0, 1)
#else
#define SH_PREFETCH(p) ((void)0)
#endif

static uint64_t swiss_hash_seed0;
static uint64_t swiss_hash_seed1;

static void init_hash_seed(void) {
    VALUE seed_val = rb_hash(INT2FIX(0));
    uint64_t base = (uint64_t)NUM2LONG(seed_val);

    uint64_t s = base ^ 0x6a09e667f3bcc908ULL;
    s ^= s >> 30;
    s *= 0xbf58476d1ce4e5b9ULL;
    s ^= s >> 27;
    s *= 0x94d049bb133111ebULL;
    s ^= s >> 31;
    swiss_hash_seed0 = s;

    s ^= s >> 30;
    s *= 0xbf58476d1ce4e5b9ULL;
    s ^= s >> 27;
    s *= 0x94d049bb133111ebULL;
    s ^= s >> 31;
    swiss_hash_seed1 = s;
}

static inline uint64_t _wyr8(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}
static inline uint64_t _wyr4(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}
static inline uint64_t _wyr3(const uint8_t *p, size_t k) {
    return ((uint64_t)p[0]) << 16 | ((uint64_t)p[k >> 1]) << 8 | p[k - 1];
}

static inline uint64_t _wymix(uint64_t a, uint64_t b) {
#if defined(_MSC_VER) && defined(_M_X64)
    uint64_t hi;
    uint64_t lo = _umul128(a, b, &hi);
    return hi ^ lo;
#elif defined(__SIZEOF_INT128__)
    __uint128_t r = (__uint128_t)a * b;
    return (uint64_t)(r >> 64) ^ (uint64_t)r;
#else
    uint64_t lo = a * b;
    uint32_t a_hi = (uint32_t)(a >> 32), a_lo = (uint32_t)a;
    uint32_t b_hi = (uint32_t)(b >> 32), b_lo = (uint32_t)b;
    uint64_t cross1 = (uint64_t)a_hi * b_lo;
    uint64_t cross2 = (uint64_t)a_lo * b_hi;
    uint64_t hi_approx = (uint64_t)a_hi * b_hi + (cross1 >> 32) + (cross2 >> 32);
    return hi_approx ^ lo;
#endif
}

static inline uint64_t wyhash(const void *data, size_t len, uint64_t seed) {
    static const uint64_t s0 = 0xa0761d6478bd642fULL;
    static const uint64_t s1 = 0xe7037ed1a0b428dbULL;
    static const uint64_t s2 = 0x8ebc6af09c88c6e3ULL;
    static const uint64_t s3 = 0x589965cc75374cc3ULL;

    const uint8_t *p = (const uint8_t *)data;
    uint64_t a, b;

    seed ^= _wymix(seed ^ s0, s1);

    if (len <= 16) {
        if (len >= 4) {
            a = (_wyr4(p) << 32) | _wyr4(p + ((len >> 3) << 2));
            b = (_wyr4(p + len - 4) << 32) | _wyr4(p + len - 4 - ((len >> 3) << 2));
        } else if (len > 0) {
            a = _wyr3(p, len);
            b = 0;
        } else {
            a = b = 0;
        }
    } else if (len <= 48) {
        size_t i = 0;
        for (; i + 16 <= len; i += 16) {
            seed = _wymix(_wyr8(p + i) ^ s1, _wyr8(p + i + 8) ^ seed);
        }
        a = _wyr8(p + len - 16);
        b = _wyr8(p + len - 8);
    } else {
        size_t i = 0;
        uint64_t see1 = seed, see2 = seed;
        for (; i + 48 <= len; i += 48) {
            seed = _wymix(_wyr8(p + i) ^ s1, _wyr8(p + i + 8) ^ seed);
            see1 = _wymix(_wyr8(p + i + 16) ^ s2, _wyr8(p + i + 24) ^ see1);
            see2 = _wymix(_wyr8(p + i + 32) ^ s3, _wyr8(p + i + 40) ^ see2);
        }
        for (; i + 16 <= len; i += 16) {
            seed = _wymix(_wyr8(p + i) ^ s1, _wyr8(p + i + 8) ^ seed);
        }
        seed ^= see1 ^ see2;
        a = _wyr8(p + len - 16);
        b = _wyr8(p + len - 8);
    }

    return _wymix(s1 ^ len, _wymix(a ^ s1, b ^ seed));
}

#define CTRL_EMPTY                0x80
#define CTRL_DELETED              0xFE
#define H2_MASK                   0x7F
#define MAX_LOAD_NUM              7
#define MAX_LOAD_DEN              8
#define TOMBSTONE_COMPACT_DIVISOR 4

#if defined(__x86_64__) || defined(_M_X64)
#define SWISS_USE_SSE2 1
#include <emmintrin.h>

#define GROUP_SIZE  16
#define GROUP_MASK  0xFFFFu
#elif defined(__aarch64__) || defined(_M_ARM64)
#define SWISS_USE_NEON 1
#include <arm_neon.h>

#define GROUP_SIZE  8
#define GROUP_MASK  0xFFu
#else
#define SWISS_USE_PORTABLE 1
#define GROUP_SIZE  8
#define GROUP_MASK  0xFFu
#endif

#ifdef SWISS_USE_SSE2

static inline __m128i ctrl_load(const uint8_t *ctrl) {
    return _mm_loadu_si128((const __m128i *)ctrl);
}

static inline uint32_t ctrl_match_h2_vec(__m128i cv, uint8_t h2) {
    __m128i cmp = _mm_cmpeq_epi8(cv, _mm_set1_epi8((char)h2));
    return (uint32_t)_mm_movemask_epi8(cmp);
}

static inline uint32_t ctrl_match_empty_vec(__m128i cv) {
    __m128i cmp = _mm_cmpeq_epi8(cv, _mm_set1_epi8((char)CTRL_EMPTY));
    return (uint32_t)_mm_movemask_epi8(cmp);
}

static inline uint32_t ctrl_match_empty_or_deleted_vec(__m128i cv) {
    return (uint32_t)_mm_movemask_epi8(cv);
}

static inline uint32_t ctrl_match_empty(const uint8_t *ctrl) {
    return ctrl_match_empty_vec(ctrl_load(ctrl));
}

#elif defined(SWISS_USE_NEON)

static inline uint32_t neon_movemask(uint8x8_t v) {
    static const uint8_t power_of_two[8] = {1, 2, 4, 8, 16, 32, 64, 128};
    uint8x8_t bits = vand_u8(v, vld1_u8(power_of_two));
    bits = vpadd_u8(bits, bits);
    bits = vpadd_u8(bits, bits);
    bits = vpadd_u8(bits, bits);
    return (uint32_t)vget_lane_u8(bits, 0);
}

static inline uint8x8_t ctrl_load(const uint8_t *ctrl) {
    return vld1_u8(ctrl);
}

static inline uint32_t ctrl_match_h2_vec(uint8x8_t cv, uint8_t h2) {
    return neon_movemask(vceq_u8(cv, vdup_n_u8(h2)));
}

static inline uint32_t ctrl_match_empty_vec(uint8x8_t cv) {
    return neon_movemask(vceq_u8(cv, vdup_n_u8(CTRL_EMPTY)));
}

static inline uint32_t ctrl_match_empty_or_deleted_vec(uint8x8_t cv) {
    uint8x8_t msb = vshr_n_u8(cv, 7);
    uint8x8_t match = vceq_u8(msb, vdup_n_u8(1));
    return neon_movemask(match);
}

static inline uint32_t ctrl_match_empty(const uint8_t *ctrl) {
    return ctrl_match_empty_vec(ctrl_load(ctrl));
}

#else /* portable */

static inline uint32_t ctrl_match_h2_raw(const uint8_t *ctrl, uint8_t h2) {
    uint64_t c;
    memcpy(&c, ctrl, 8);
    uint64_t broadcast = 0x0101010101010101ULL * h2;
    uint64_t xored = c ^ broadcast;
    uint64_t result = (xored - 0x0101010101010101ULL) & ~xored & 0x8080808080808080ULL;
    uint32_t mask = 0;
    for (int i = 0; i < 8; i++) {
        if (result & (0x80ULL << (i * 8)))
            mask |= (1u << i);
    }
    return mask;
}

static inline uint32_t ctrl_match_empty_raw(const uint8_t *ctrl) {
    uint32_t mask = 0;
    for (int i = 0; i < 8; i++) {
        if (ctrl[i] == CTRL_EMPTY)
            mask |= (1u << i);
    }
    return mask;
}

static inline uint32_t ctrl_match_empty_or_deleted_raw(const uint8_t *ctrl) {
    uint32_t mask = 0;
    for (int i = 0; i < 8; i++) {
        if (ctrl[i] & 0x80)
            mask |= (1u << i);
    }
    return mask;
}

static inline uint32_t ctrl_match_empty(const uint8_t *ctrl) {
    return ctrl_match_empty_raw(ctrl);
}

#endif /* SIMD selection */

static inline int ctz32(uint32_t v) {
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_ctz(v);
#elif defined(_MSC_VER)
    unsigned long idx;
    _BitScanForward(&idx, v);
    return (int)idx;
#else
    int n = 0;
    while (!(v & 1)) {
        v >>= 1;
        n++;
    }
    return n;
#endif
}

typedef struct {
    VALUE key;
    VALUE value;
} Slot;

typedef struct {
    uint8_t *ctrl;
    Slot *slots;
    size_t capacity;
    size_t num_groups;
    size_t group_mask;
    size_t size;
    size_t growth_left;
    size_t tombstone_count;
    uint8_t mutating;
} SwissHash;

#define MUTATE_GUARD_BEGIN(sh)                                                               \
    do {                                                                                     \
        if ((sh)->mutating) {                                                                \
            rb_raise(rb_eRuntimeError, "SwissHash: reentrant modification detected "         \
                                       "(#hash or #eql? callback modified the same table)"); \
        }                                                                                    \
        (sh)->mutating = 1;                                                                  \
    } while (0)

#define MUTATE_GUARD_END(sh) \
    do {                     \
        (sh)->mutating = 0;  \
    } while (0)

#define FIBONACCI_HASH_C 0x9E3779B97F4A7C15ULL

static inline uint64_t compute_hash(VALUE key) {
    uint64_t v;

    if (FIXNUM_P(key)) {
        v = (uint64_t)FIX2LONG(key) ^ swiss_hash_seed0;
        return v * FIBONACCI_HASH_C;
    }

    if (SYMBOL_P(key)) {
        v = (uint64_t)SYM2ID(key) ^ swiss_hash_seed0;
        return v * FIBONACCI_HASH_C;
    }

    if (RB_TYPE_P(key, T_STRING)) {
        const char *ptr = RSTRING_PTR(key);
        long len = RSTRING_LEN(key);
        int enc_idx = ENCODING_GET(key);
        uint64_t str_seed = swiss_hash_seed0 ^ (uint64_t)enc_idx;
        return wyhash(ptr ? ptr : (const char *)"", (size_t)len, str_seed);
    }

    v = (uint64_t)NUM2LONG(rb_hash(key));
    v ^= swiss_hash_seed1;
    v ^= v >> 33;
    v *= 0xff51afd7ed558ccdULL;
    v ^= v >> 33;
    v *= 0xc4ceb9fe1a85ec53ULL;
    v ^= v >> 33;
    return v;
}

#define H1(hash) ((hash) >> 7)
#define H2(hash) ((uint8_t)((hash) & H2_MASK))

static inline int keys_equal(VALUE a, VALUE b) {
    if (a == b) return 1;
    if (FIXNUM_P(a) || SYMBOL_P(a) || SPECIAL_CONST_P(a)) return 0;

    if (RB_TYPE_P(a, T_STRING) && RB_TYPE_P(b, T_STRING)) {
        long la = RSTRING_LEN(a);
        if (la != RSTRING_LEN(b)) return 0;
        const char *pa = RSTRING_PTR(a);
        const char *pb = RSTRING_PTR(b);
        if (pa == pb) return 1;

        int ea = ENCODING_GET(a);
        int eb = ENCODING_GET(b);
        if (ea == eb) {
            return memcmp(pa, pb, (size_t)la) == 0;
        }

        if (ENC_CODERANGE(a) == ENC_CODERANGE_7BIT &&
            ENC_CODERANGE(b) == ENC_CODERANGE_7BIT) {
            return memcmp(pa, pb, (size_t)la) == 0;
        }

        if (rb_enc_compatible(a, b)) {
            return memcmp(pa, pb, (size_t)la) == 0;
        }
        return rb_eql(a, b);
    }

    return rb_eql(a, b);
}

static inline VALUE prepare_key(VALUE key) {
    if (RB_TYPE_P(key, T_STRING)) {
        if (!OBJ_FROZEN(key)) {
            key = rb_str_new_frozen(key);
        }

        rb_enc_str_coderange(key);
    }
    return key;
}

static void swiss_free_arrays(SwissHash *sh) {
    free(sh->ctrl);
    sh->ctrl = NULL;
    free(sh->slots);
    sh->slots = NULL;
}

static void swiss_init(SwissHash *sh, size_t min_capacity) {
    size_t min_groups = (min_capacity + GROUP_SIZE - 1) / GROUP_SIZE;
    size_t num_groups = 1;
    while (num_groups < min_groups)
        num_groups <<= 1;
    if (num_groups < 2)
        num_groups = 2;

    size_t capacity = num_groups * GROUP_SIZE;

    sh->num_groups = num_groups;
    sh->group_mask = num_groups - 1;
    sh->capacity = capacity;
    sh->size = 0;
    sh->tombstone_count = 0;
    sh->mutating = 0;
    sh->growth_left = capacity * MAX_LOAD_NUM / MAX_LOAD_DEN;

    sh->ctrl = (uint8_t *)malloc(capacity);
    sh->slots = (Slot *)malloc(capacity * sizeof(Slot));

    if (!sh->ctrl || !sh->slots) {
        free(sh->ctrl);
        free(sh->slots);
        sh->ctrl = NULL;
        sh->slots = NULL;
        rb_raise(rb_eNoMemError, "failed to allocate SwissHash");
    }

    memset(sh->ctrl, CTRL_EMPTY, capacity);
}

typedef struct {
    size_t group_idx;
    size_t stride;
    size_t group_mask;
} ProbeSeq;

static inline ProbeSeq probe_start(uint64_t h1, size_t group_mask) {
    ProbeSeq ps;
    ps.group_idx = (size_t)(h1)&group_mask;
    ps.stride = 0;
    ps.group_mask = group_mask;
    return ps;
}

static inline void probe_next(ProbeSeq *ps) {
    ps->stride++;
    ps->group_idx = (ps->group_idx + ps->stride) & ps->group_mask;
}

#define GROUP_OFF(gi) ((gi) * GROUP_SIZE)

static VALUE *swiss_lookup(SwissHash *sh, VALUE key) {
    uint64_t hash = compute_hash(key);
    uint8_t h2 = H2(hash);
    ProbeSeq ps = probe_start(H1(hash), sh->group_mask);

    for (;;) {
        size_t off = GROUP_OFF(ps.group_idx);

#if defined(SWISS_USE_SSE2)
        __m128i cv = ctrl_load(sh->ctrl + off);
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_vec(cv, h2);
        uint32_t empty = ctrl_match_empty_vec(cv);
#elif defined(SWISS_USE_NEON)
        uint8x8_t cv = ctrl_load(sh->ctrl + off);
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_vec(cv, h2);
        uint32_t empty = ctrl_match_empty_vec(cv);
#else
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_raw(sh->ctrl + off, h2);
        uint32_t empty = ctrl_match_empty_raw(sh->ctrl + off);
#endif
        while (match) {
            int slot = ctz32(match);
            Slot *s = &sh->slots[off + slot];
            if (keys_equal(s->key, key)) {
                return &s->value;
            }
            match &= match - 1;
        }

        if (empty)
            return NULL;
        probe_next(&ps);
    }
}

static void swiss_grow(SwissHash *sh);
static void swiss_compact(SwissHash *sh);

static inline void swiss_insert_rehash(SwissHash *sh, uint64_t hash, VALUE key, VALUE value) {
    uint8_t h2 = H2(hash);
    ProbeSeq ps = probe_start(H1(hash), sh->group_mask);

    for (;;) {
        size_t off = GROUP_OFF(ps.group_idx);
        uint32_t empty_mask = ctrl_match_empty(sh->ctrl + off);
        if (empty_mask) {
            size_t idx = off + ctz32(empty_mask);
            sh->ctrl[idx] = h2;
            sh->slots[idx].key = key;
            sh->slots[idx].value = value;
            sh->size++;
            sh->growth_left--;
            return;
        }
        probe_next(&ps);
    }
}

static inline int should_compact(SwissHash *sh) {
    return sh->tombstone_count >= sh->capacity / TOMBSTONE_COMPACT_DIVISOR;
}

static void swiss_compact(SwissHash *sh) {
    size_t cap = sh->capacity;
    size_t old_size = sh->size;

    uint8_t *old_ctrl = sh->ctrl;
    Slot *old_slots = sh->slots;

    sh->ctrl = (uint8_t *)malloc(cap);
    sh->slots = (Slot *)malloc(cap * sizeof(Slot));

    if (!sh->ctrl || !sh->slots) {
        free(sh->ctrl);
        free(sh->slots);
        sh->ctrl = old_ctrl;
        sh->slots = old_slots;
        sh->size = old_size;
        sh->growth_left = 0;
        rb_raise(rb_eNoMemError, "failed to compact SwissHash");
    }

    memset(sh->ctrl, CTRL_EMPTY, cap);
    sh->size = 0;
    sh->growth_left = cap * MAX_LOAD_NUM / MAX_LOAD_DEN;
    sh->tombstone_count = 0;

    for (size_t i = 0; i < cap; i++) {
        uint8_t c = old_ctrl[i];
        if (c != CTRL_EMPTY && c != CTRL_DELETED) {
            uint64_t hash = compute_hash(old_slots[i].key);
            swiss_insert_rehash(sh, hash, old_slots[i].key, old_slots[i].value);
        }
    }

    free(old_ctrl);
    free(old_slots);
}

static VALUE swiss_insert(SwissHash *sh, VALUE key, VALUE value) {
    if (sh->growth_left == 0) {
        if (should_compact(sh)) {
            swiss_compact(sh);
        } else {
            swiss_grow(sh);
        }
    }

    uint64_t hash = compute_hash(key);
    uint8_t h2 = H2(hash);
    ProbeSeq ps = probe_start(H1(hash), sh->group_mask);

    size_t insert_idx = (size_t)-1;

    for (;;) {
        size_t off = GROUP_OFF(ps.group_idx);

#if defined(SWISS_USE_SSE2)
        __m128i cv = ctrl_load(sh->ctrl + off);
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_vec(cv, h2);
        uint32_t empty = ctrl_match_empty_vec(cv);
        uint32_t avail = ctrl_match_empty_or_deleted_vec(cv);
#elif defined(SWISS_USE_NEON)
        uint8x8_t cv = ctrl_load(sh->ctrl + off);
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_vec(cv, h2);
        uint32_t empty = ctrl_match_empty_vec(cv);
        uint32_t avail = ctrl_match_empty_or_deleted_vec(cv);
#else
        uint32_t match = ctrl_match_h2_raw(sh->ctrl + off, h2);
        uint32_t empty = ctrl_match_empty_raw(sh->ctrl + off);
        uint32_t avail = ctrl_match_empty_or_deleted_raw(sh->ctrl + off);
#endif
        while (match) {
            int slot = ctz32(match);
            size_t idx = off + slot;
            if (keys_equal(sh->slots[idx].key, key)) {
                sh->slots[idx].value = value;
                return value;
            }
            match &= match - 1;
        }

        if (insert_idx == (size_t)-1 && avail) {
            insert_idx = off + ctz32(avail);
        }

        if (empty)
            break;
        probe_next(&ps);
    }

    MUTATE_GUARD_BEGIN(sh);

    if (sh->ctrl[insert_idx] == CTRL_EMPTY) {
        sh->growth_left--;
    } else {
        sh->tombstone_count--;
    }
    sh->ctrl[insert_idx] = h2;
    sh->slots[insert_idx].key = key;
    sh->slots[insert_idx].value = value;
    sh->size++;

    MUTATE_GUARD_END(sh);
    return value;
}

static VALUE swiss_delete(SwissHash *sh, VALUE key) {
    uint64_t hash = compute_hash(key);
    uint8_t h2 = H2(hash);
    ProbeSeq ps = probe_start(H1(hash), sh->group_mask);

    for (;;) {
        size_t off = GROUP_OFF(ps.group_idx);

#if defined(SWISS_USE_SSE2)
        __m128i cv = ctrl_load(sh->ctrl + off);
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_vec(cv, h2);
        uint32_t empty = ctrl_match_empty_vec(cv);
#elif defined(SWISS_USE_NEON)
        uint8x8_t cv = ctrl_load(sh->ctrl + off);
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_vec(cv, h2);
        uint32_t empty = ctrl_match_empty_vec(cv);
#else
        SH_PREFETCH(&sh->slots[off]);
        uint32_t match = ctrl_match_h2_raw(sh->ctrl + off, h2);
        uint32_t empty = ctrl_match_empty_raw(sh->ctrl + off);
#endif
        while (match) {
            int slot = ctz32(match);
            size_t idx = off + slot;
            if (keys_equal(sh->slots[idx].key, key)) {
                VALUE old_value = sh->slots[idx].value;

                MUTATE_GUARD_BEGIN(sh);
                sh->ctrl[idx] = CTRL_DELETED;
                sh->slots[idx].key = Qnil;
                sh->slots[idx].value = Qnil;
                sh->size--;
                sh->tombstone_count++;
                MUTATE_GUARD_END(sh);

                return old_value;
            }
            match &= match - 1;
        }

        if (empty)
            return Qnil;
        probe_next(&ps);
    }
}

static void swiss_grow(SwissHash *sh) {
    size_t old_cap = sh->capacity;
    size_t old_size = sh->size;

    uint8_t *old_ctrl = sh->ctrl;
    Slot *old_slots = sh->slots;

    size_t new_num_groups = sh->num_groups * 2;
    size_t new_cap = new_num_groups * GROUP_SIZE;

    sh->ctrl = (uint8_t *)malloc(new_cap);
    sh->slots = (Slot *)malloc(new_cap * sizeof(Slot));

    if (!sh->ctrl || !sh->slots) {
        free(sh->ctrl);
        free(sh->slots);
        sh->ctrl = old_ctrl;
        sh->slots = old_slots;
        sh->size = old_size;
        sh->growth_left = 0;
        rb_raise(rb_eNoMemError, "failed to grow SwissHash");
    }

    memset(sh->ctrl, CTRL_EMPTY, new_cap);

    sh->num_groups = new_num_groups;
    sh->group_mask = new_num_groups - 1;
    sh->capacity = new_cap;
    sh->size = 0;
    sh->growth_left = new_cap * MAX_LOAD_NUM / MAX_LOAD_DEN;
    sh->tombstone_count = 0;

    for (size_t i = 0; i < old_cap; i++) {
        uint8_t c = old_ctrl[i];
        if (c != CTRL_EMPTY && c != CTRL_DELETED) {
            uint64_t hash = compute_hash(old_slots[i].key);
            swiss_insert_rehash(sh, hash, old_slots[i].key, old_slots[i].value);
        }
    }

    free(old_ctrl);
    free(old_slots);
}

static void swiss_hash_mark(void *ptr) {
    SwissHash *sh = (SwissHash *)ptr;
    if (!sh || !sh->ctrl)
        return;

    for (size_t i = 0; i < sh->capacity; i++) {
        uint8_t c = sh->ctrl[i];
        if (c != CTRL_EMPTY && c != CTRL_DELETED) {
            rb_gc_mark(sh->slots[i].key);
            rb_gc_mark(sh->slots[i].value);
        }
    }
}

static void swiss_hash_free(void *ptr) {
    SwissHash *sh = (SwissHash *)ptr;
    if (sh) {
        swiss_free_arrays(sh);
        free(sh);
    }
}

static size_t swiss_hash_memsize(const void *ptr) {
    const SwissHash *sh = (const SwissHash *)ptr;
    size_t s = sizeof(SwissHash);
    if (sh && sh->ctrl) {
        s += sh->capacity * (sizeof(uint8_t) + sizeof(Slot));
    }
    return s;
}

static const rb_data_type_t swiss_hash_type = {
    "SwissHash",
    {swiss_hash_mark, swiss_hash_free, swiss_hash_memsize},
    NULL,
    NULL,
    RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE swiss_hash_alloc(VALUE klass) {
    SwissHash *sh = ALLOC(SwissHash);
    memset(sh, 0, sizeof(SwissHash));
    return TypedData_Wrap_Struct(klass, &swiss_hash_type, sh);
}

static VALUE swiss_hash_initialize(int argc, VALUE *argv, VALUE self) {
    VALUE capacity_val;
    rb_scan_args(argc, argv, "01", &capacity_val);

    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);

    size_t capacity = NIL_P(capacity_val) ? 16 : NUM2SIZET(capacity_val);
    swiss_init(sh, capacity);

    return self;
}

static VALUE swiss_hash_aset(VALUE self, VALUE key, VALUE value) {
    SwissHash *sh = (SwissHash *)RTYPEDDATA_DATA(self);
    if (RB_UNLIKELY(!(FIXNUM_P(key) || SYMBOL_P(key)))) {
        key = prepare_key(key);
    }
    return swiss_insert(sh, key, value);
}

static VALUE swiss_hash_aref(VALUE self, VALUE key) {
    SwissHash *sh = (SwissHash *)RTYPEDDATA_DATA(self);
    VALUE *val = swiss_lookup(sh, key);
    return val ? *val : Qnil;
}

static VALUE swiss_hash_delete(VALUE self, VALUE key) {
    SwissHash *sh = (SwissHash *)RTYPEDDATA_DATA(self);
    return swiss_delete(sh, key);
}

static VALUE swiss_hash_size(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);
    return SIZET2NUM(sh->size);
}

static VALUE swiss_hash_empty_p(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);
    return sh->size == 0 ? Qtrue : Qfalse;
}

static VALUE swiss_hash_clear(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);

    memset(sh->ctrl, CTRL_EMPTY, sh->capacity);
    memset(sh->slots, 0, sh->capacity * sizeof(Slot));
    sh->size = 0;
    sh->growth_left = sh->capacity * MAX_LOAD_NUM / MAX_LOAD_DEN;
    sh->tombstone_count = 0;

    return self;
}

static VALUE swiss_hash_each(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);

    RETURN_ENUMERATOR(self, 0, 0);

    for (size_t i = 0; i < sh->capacity; i++) {
        uint8_t c = sh->ctrl[i];
        if (c != CTRL_EMPTY && c != CTRL_DELETED) {
            rb_yield_values(2, sh->slots[i].key, sh->slots[i].value);
        }
    }

    return self;
}

static VALUE swiss_hash_keys(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);
    VALUE ary = rb_ary_new_capa(sh->size);

    for (size_t i = 0; i < sh->capacity; i++) {
        uint8_t c = sh->ctrl[i];
        if (c != CTRL_EMPTY && c != CTRL_DELETED) {
            rb_ary_push(ary, sh->slots[i].key);
        }
    }
    return ary;
}

static VALUE swiss_hash_values(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);
    VALUE ary = rb_ary_new_capa(sh->size);

    for (size_t i = 0; i < sh->capacity; i++) {
        uint8_t c = sh->ctrl[i];
        if (c != CTRL_EMPTY && c != CTRL_DELETED) {
            rb_ary_push(ary, sh->slots[i].value);
        }
    }
    return ary;
}

static VALUE swiss_hash_key_p(VALUE self, VALUE key) {
    SwissHash *sh = (SwissHash *)RTYPEDDATA_DATA(self);
    VALUE *val = swiss_lookup(sh, key);
    return val ? Qtrue : Qfalse;
}

static VALUE swiss_hash_compact_bang(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);

    if (sh->tombstone_count > 0) {
        swiss_compact(sh);
    }

    return self;
}

static VALUE swiss_hash_stats(VALUE self) {
    SwissHash *sh;
    TypedData_Get_Struct(self, SwissHash, &swiss_hash_type, sh);

    double load = sh->capacity > 0 ? (double)sh->size / sh->capacity : 0.0;

    VALUE hash = rb_hash_new();
    rb_hash_aset(hash, ID2SYM(rb_intern("capacity")), SIZET2NUM(sh->capacity));
    rb_hash_aset(hash, ID2SYM(rb_intern("size")), SIZET2NUM(sh->size));
    rb_hash_aset(hash, ID2SYM(rb_intern("num_groups")), SIZET2NUM(sh->num_groups));
    rb_hash_aset(hash, ID2SYM(rb_intern("load_factor")), DBL2NUM(load));
    rb_hash_aset(hash, ID2SYM(rb_intern("memory_bytes")), SIZET2NUM(swiss_hash_memsize(sh)));
    rb_hash_aset(hash, ID2SYM(rb_intern("growth_left")), SIZET2NUM(sh->growth_left));
    rb_hash_aset(hash, ID2SYM(rb_intern("tombstones")), SIZET2NUM(sh->tombstone_count));

#ifdef SWISS_USE_SSE2
    rb_hash_aset(hash, ID2SYM(rb_intern("simd")), rb_str_new_cstr("SSE2"));
#elif defined(SWISS_USE_NEON)
    rb_hash_aset(hash, ID2SYM(rb_intern("simd")), rb_str_new_cstr("NEON"));
#else
    rb_hash_aset(hash, ID2SYM(rb_intern("simd")), rb_str_new_cstr("portable/SWAR"));
#endif
    rb_hash_aset(hash, ID2SYM(rb_intern("layout")), rb_str_new_cstr("hybrid"));

    return hash;
}

void Init_swiss_hash(void) {
    init_hash_seed();

    VALUE mSwissHash = rb_define_module("SwissHash");
    VALUE cHash = rb_define_class_under(mSwissHash, "Hash", rb_cObject);

    rb_define_alloc_func(cHash, swiss_hash_alloc);
    rb_define_method(cHash, "initialize", swiss_hash_initialize, -1);
    rb_define_method(cHash, "[]=", swiss_hash_aset, 2);
    rb_define_method(cHash, "store", swiss_hash_aset, 2);
    rb_define_method(cHash, "[]", swiss_hash_aref, 1);
    rb_define_method(cHash, "delete", swiss_hash_delete, 1);
    rb_define_method(cHash, "size", swiss_hash_size, 0);
    rb_define_method(cHash, "length", swiss_hash_size, 0);
    rb_define_method(cHash, "empty?", swiss_hash_empty_p, 0);
    rb_define_method(cHash, "clear", swiss_hash_clear, 0);
    rb_define_method(cHash, "each", swiss_hash_each, 0);
    rb_define_method(cHash, "keys", swiss_hash_keys, 0);
    rb_define_method(cHash, "values", swiss_hash_values, 0);
    rb_define_method(cHash, "key?", swiss_hash_key_p, 1);
    rb_define_method(cHash, "has_key?", swiss_hash_key_p, 1);
    rb_define_method(cHash, "include?", swiss_hash_key_p, 1);
    rb_define_method(cHash, "compact!", swiss_hash_compact_bang, 0);
    rb_define_method(cHash, "stats", swiss_hash_stats, 0);
}
