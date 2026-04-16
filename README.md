# SwissHash

Swiss Table hash map implementation as a Ruby C extension. Based on the design principles from Google's [Abseil](https://abseil.io/about/design/swisstables) flat_hash_map, Rust's [hashbrown](https://github.com/rust-lang/hashbrown), and [Go 1.24 Swiss Tables](https://go.dev/blog/swisstable), with architecture adapted for Ruby's object system.

## Installation

```
gem install swiss_hash
```

## Usage

```ruby
require "swiss_hash"

h = SwissHash::Hash.new
h["key"] = "value"
h["key"] # => "value"
h.delete("key")
h.stats # => { capacity: 16, size: 0, ... }
```

## Performance Results

Benchmarks on Ruby 3.1.7 / arm64-darwin24 (Apple Silicon, NEON SIMD).

Methodology: 21 iterations per test, 5 warmup runs, IQR-filtered mean, **interleaved Ruby/SwissHash measurements** per iteration with alternating start order to cancel out thermal drift and scheduling noise. Per-side coefficient of variation reported to distinguish real deltas from noise.

### N = 100,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---|---|---|
| Insert (string keys) | 17.6 ms | 11.3 ms | **−35.8%** ⚡ |
| Delete + reinsert 25% | 9.8 ms | 8.9 ms | **−9.0%** |
| Insert (sequential int) | 7.0 ms | 6.4 ms | **−8.7%** |
| Mixed (70% read / 20% write / 10% delete) | 21.4 ms | 19.6 ms | **−8.6%** |
| Insert (random int) | 6.7 ms | 6.4 ms | **−3.5%** |
| Lookup (string keys) | 20.3 ms | 20.8 ms | +2.5% |
| Lookup (sequential int) | 11.7 ms | 12.2 ms | +4.4% |

### N = 10,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---|---|---|
| Insert (string keys) | 1.63 ms | 1.10 ms | **−32.8%** ⚡ |
| **Lookup (string keys)** | 1.71 ms | 1.62 ms | **−5.2%** ⚡ |
| Mixed | 1.93 ms | 1.90 ms | −1.6% |
| Delete + reinsert | 0.91 ms | 0.89 ms | −2.0% |
| Insert (sequential int) | 0.66 ms | 0.67 ms | +2.5% |
| Lookup (sequential int) | 1.05 ms | 1.12 ms | +6.0% |

### N = 1,000

Ruby Hash uses an AR-table (flat array, linear search) for small hashes — SwissHash doesn't have this small-map regime, so for very small integer-keyed workloads Ruby wins. String workloads still favour SwissHash due to wyhash and the lookup fast path.

| Operation | Ruby Hash | SwissHash | Delta |
|---|---|---|---|
| Insert (string keys) | 0.183 ms | 0.118 ms | **−35.6%** ⚡ |
| **Lookup (string keys)** | 0.184 ms | 0.155 ms | **−15.5%** ⚡ |
| Insert (sequential int) | 0.063 ms | 0.074 ms | +17.5% |
| Delete + reinsert | 0.094 ms | 0.102 ms | +8.2% |

### Summary

- **Faster on 5 of 7 operations** at N=100k, some substantially (−36% string insert, −9% mixed workload, −9% delete+reinsert).
- **Strictly faster for string keys** at every size (25–35% faster inserts, break-even to 15% faster lookups).
- **Near parity on lookups** at N=100k (+2.5% on strings, +4.4% on ints) — remaining gap stems from Ruby VM's opcode specialization for `Hash#[]`, not the data structure.

### Memory Usage

For 100,000 integer keys:
- **SwissHash**: 2,176 KB contiguous native memory, 4 GC slots
- **Ruby Hash**: managed via GC slots (not directly measurable)
- **Load factor**: 76.3% actual (max 87.5%)
- **GC pressure**: zero GC runs during insertion

## Features

- **SIMD-optimized probing**: SSE2 (16-byte groups) on x86_64, NEON (8-byte groups) on ARM64, SWAR fallback elsewhere
- **Memory efficient**: Swiss Table layout with 87.5% max load factor
- **Tombstone compaction**: Automatic cleanup of deleted entries during resize
- **Ruby compatibility**: Supports frozen string keys, all Ruby object types
- **Thread safety**: Prevents reentrant modifications during callbacks

## API

```ruby
hash = SwissHash::Hash.new(capacity = 16)

# Basic operations
hash[key] = value
hash[key]          # get, returns nil if absent
hash.delete(key)   # returns old value or nil

# Enumeration
hash.each { |k, v| ... }
hash.keys
hash.values

# Size and status
hash.size          # also: length
hash.empty?
hash.key?(key)     # also: has_key?, include?

# Maintenance
hash.clear
hash.compact!      # drop tombstones without reallocating

# Debugging
hash.stats         # => { capacity:, size:, num_groups:, load_factor:,
                   #      memory_bytes:, growth_left:, tombstones:, simd: }
```

## Usage Recommendations

Use SwissHash when:
- Your hash keys are **strings** — inserts are 25–35% faster, lookups are on par or faster
- Your hash holds **10,000+ entries** with any mix of reads, writes, and deletes
- You do **heavy delete/reinsert churn** — tombstone compaction handles it without pathological slowdown
- You need **predictable native memory** instead of scattered GC allocations

Stick with Ruby's built-in `Hash` when:
- Your hash is small (≤ a few hundred entries) and mostly lookup-heavy with integer keys — Ruby's AR-table wins for small integer-keyed workloads
- You depend on Hash-specific semantics: default blocks, `compare_by_identity`, full insertion-order guarantees, or the complete `Hash` API

## Architecture

### Swiss Table core
- **Open addressing** with 7-bit `H2` metadata byte per slot; SIMD rejects non-matching slots in parallel
- **Group size 16 on SSE2** (full `_mm_movemask_epi8` width, matching Abseil / hashbrown); **group size 8 on NEON** and portable SWAR fallback — matches hashbrown's deliberate ARM choice (NEON's multi-cycle movemask latency makes 16-wide groups lose to 8-wide SWAR)
- **Triangular probing** — `i(i+1)/2` — guarantees full coverage on power-of-2 capacities
- **Max load factor 87.5%** (7/8)

### Ruby-specific adaptations
- **wyhash** for string keys — faster than Ruby's SipHash on short strings, which dominate typical workloads
- **Fibonacci multiplicative hash** for Fixnum and Symbol keys — their low bits are already well-distributed, so avalanche mixers would be wasted work
- **ASCII-7bit fast-path** in key equality: frozen string keys have their coderange pre-computed on insert, so subsequent lookup comparisons skip `rb_enc_compatible` entirely and go straight to `memcmp`
- **Encoding-index equality check** as the first fast path in key comparison — avoids `rb_enc_compatible` on the common case of matching encodings
- **Inline `RTYPEDDATA_DATA`** on hot methods (`[]`, `[]=`, `delete`, `key?`) — skips the type-check overhead of `TypedData_Get_Struct` on every operation
- **Prefetch `slots[off]`** right after the control-byte load so DRAM fetch overlaps with SIMD match extraction

### Memory layout
- Separate control-byte array and slot array (hashbrown-style) — the tight control array scans well through L1/L2
- No zero-initialization of slot memory (`malloc` instead of `calloc`) — slots are only ever read after their control byte confirms they're live

## Build

```
rake compile
```

## Benchmarking

The included `benchmark.rb` produces statistically honest results:

```bash
bundle exec ruby benchmark.rb
```

Key features that make it trustworthy:
- **Interleaved Ruby/SwissHash measurements** per iteration with alternating start order — thermal throttling and fluctuating background load hit both sides equally
- **21 iterations with IQR-filtered mean** (trims top and bottom 25%) — more robust than median on noisy laptop hardware
- **5 warmup runs** to settle JIT, caches, and branch predictor
- **Per-side coefficient of variation** (`±X.X%`) displayed so you can distinguish a real 5% delta from 5% noise
- **Correctness smoke test** runs before measurement

### Profiling

For profiling on macOS:

```bash
bundle exec ruby simp.rb            # runs infinite lookup loop, prints PID
sample <PID> 60 -f /tmp/swiss.sample
filtercalltree /tmp/swiss.sample | head -100
```

## Design References

- Matt Kulukundis, ["Designing a Fast, Efficient, Cache-friendly Hash Table, Step by Step"](https://www.youtube.com/watch?v=ncHmEUmJZf4) — CppCon 2017
- [Abseil: SwissTables design](https://abseil.io/about/design/swisstables)
- [rust-lang/hashbrown](https://github.com/rust-lang/hashbrown) — reference for SSE2/NEON/SWAR strategy choices
- [Go 1.24 maps](https://go.dev/blog/swisstable) — probing and resize design trade-offs
- Aria Beingessner, ["Swisstable, a Quick and Dirty Description"](https://faultlore.com/blah/hashbrown-tldr/) — implementer's notes

## License

MIT
