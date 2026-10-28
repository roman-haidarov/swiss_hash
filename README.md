# SwissHash

Swiss Table hash map implementation as a Ruby C extension. The design follows the same broad family as Google's [Abseil](https://abseil.io/about/design/swisstables) `flat_hash_map`, Rust's [hashbrown](https://github.com/rust-lang/hashbrown), and [Go 1.24 Swiss Tables](https://go.dev/blog/swisstable), with Ruby-specific hashing, key preparation, GC integration, and a Hash-like API surface.

## Installation

```bash
gem install swiss_hash
```

## Usage

```ruby
require "swiss_hash"

h = SwissHash::Hash.new
h["key"] = "value"
h["key"]          # => "value"
h.fetch("key")    # => "value"
h.delete("key")   # => "value"
h.stats            # => { capacity: 16, size: 0, ... }
```

`SwissHash::Hash` is intentionally not a subclass of Ruby's built-in `Hash`. Use `to_h` when you need a real Ruby `Hash`, and `to_sh` when you want a shallow SwissHash copy.

## Performance Results

Benchmarks below were produced by `benchmark.rb` on Ruby 3.4.3 / arm64-darwin24.

Methodology: 10 runs × 21 measured iterations, 5 warmup iterations per run, IQR-filtered mean per run, interleaved Ruby/SwissHash measurements with alternating start order, and per-side coefficient of variation (`±X.X%`) reported to make noise visible.

### N = 100,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (sequential int) | 6.412 ms (±0.5%) | 4.973 ms (±0.7%) | **−22.44%** ⚡ |
| Insert (string keys) | 16.130 ms (±0.2%) | 10.470 ms (±0.2%) | **−35.09%** ⚡ |
| Insert (random int) | 5.994 ms (±0.6%) | 4.763 ms (±0.8%) | **−20.55%** ⚡ |
| Lookup (sequential int, 3x) | 12.204 ms (±0.1%) | 11.050 ms (±0.1%) | **−9.46%** ⚡ |
| Lookup (string keys, 3x) | 20.465 ms (±0.2%) | 20.322 ms (±0.2%) | **−0.70%** ⚡ |
| Delete + reinsert 25% | 8.968 ms (±0.3%) | 7.075 ms (±0.4%) | **−21.10%** ⚡ |
| Mixed (70/20/10 R/W/D) | 22.168 ms (±0.3%) | 18.818 ms (±0.1%) | **−15.11%** ⚡ |

### N = 10,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (sequential int) | 0.577 ms (±1.2%) | 0.499 ms (±1.5%) | **−13.58%** ⚡ |
| Insert (string keys) | 1.479 ms (±1.6%) | 1.001 ms (±1.3%) | **−32.30%** ⚡ |
| Insert (random int) | 0.541 ms (±1.9%) | 0.470 ms (±2.2%) | **−13.10%** ⚡ |
| Lookup (sequential int, 3x) | 1.069 ms (±0.2%) | 1.035 ms (±0.2%) | **−3.22%** ⚡ |
| Lookup (string keys, 3x) | 1.692 ms (±0.4%) | 1.550 ms (±0.4%) | **−8.42%** ⚡ |
| Delete + reinsert 25% | 0.808 ms (±0.9%) | 0.701 ms (±0.7%) | **−13.33%** ⚡ |
| Mixed (70/20/10 R/W/D) | 1.979 ms (±0.6%) | 1.829 ms (±0.8%) | **−7.62%** ⚡ |

### N = 1,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (sequential int) | 0.057 ms (±0.8%) | 0.053 ms (±1.3%) | **−6.53%** ⚡ |
| Insert (string keys) | 0.154 ms (±2.7%) | 0.103 ms (±0.9%) | **−32.69%** ⚡ |
| Insert (random int) | 0.054 ms (±1.4%) | 0.049 ms (±1.1%) | **−9.27%** ⚡ |
| Lookup (sequential int, 3x) | 0.110 ms (±0.5%) | 0.106 ms (±0.4%) | **−3.73%** ⚡ |
| Lookup (string keys, 3x) | 0.177 ms (±0.5%) | 0.151 ms (±0.4%) | **−14.37%** ⚡ |
| Delete + reinsert 25% | 0.081 ms (±0.8%) | 0.074 ms (±1.1%) | **−8.42%** ⚡ |
| Mixed (70/20/10 R/W/D) | 0.203 ms (±0.2%) | 0.191 ms (±0.3%) | **−5.88%** ⚡ |

### Summary

- SwissHash is faster on all seven listed operations at N=100k; string lookup is within 1% of Ruby Hash.
- The strongest win is string-key insertion: **−32% to −35%** across tested sizes.
- ARM64 uses the NEON group-matching path (`stats[:simd] => "NEON"`).
- Ruby's built-in `Hash` remains excellent, especially for very small maps and cases that benefit from VM-level Hash specialization.

### Memory Usage

For 100,000 entries, `ObjectSpace.memsize_of` reports the hash object/table and directly retained key/value objects. Integer keys and values are immediate values, so they add no separate object bytes. For string-key tests, stored string keys are counted; the shared input array and source strings are excluded from both totals.

| Workload | Implementation | Container | Referenced keys/values | Total |
|---|---|---:|---:|---:|
| Integer keys and values | SwissHash | 2,176.1 KiB | 0.0 KiB | 2,176.1 KiB |
| Integer keys and values | Ruby Hash | 4,096.2 KiB | 0.0 KiB | 4,096.2 KiB |
| String keys and integer values | SwissHash | 2,176.1 KiB | 6,408.1 KiB | 8,584.2 KiB |
| String keys and integer values | Ruby Hash | 4,096.2 KiB | 6,408.1 KiB | 10,504.3 KiB |

SwissHash uses 46.87% less measured memory for integer entries and 18.28% less for string-key entries. The measurement excludes allocator fragmentation and objects reachable only through nested values. Load factor: 76.3%; max load factor: 87.5%; SIMD path: NEON.

## Features

- **Swiss Table probing**: 7-bit `H2` metadata, group probing, triangular probe sequence, and 87.5% max load factor.
- **SIMD group matching**: SSE2 on x86_64, NEON on aarch64, SWAR fallback elsewhere.
- **Fast string-key path**: wyhash for string keys, frozen string key preparation, 7-bit strings of different encodings hash/compare like Ruby Hash, and direct `memcmp` when encodings are compatible.
- **Low GC pressure**: keys and values are Ruby objects, while control bytes and slots live in contiguous native arrays.
- **Delete/reinsert friendly**: tombstones are tracked and compacted to avoid pathological slowdown.
- **Hash-like API**: basic accessors, enumeration, fetch helpers, merge/update/replace, filtering, transforming, slicing, inversion, and conversion helpers.
- **Native hot paths**: performance-critical methods are implemented in C; small convenience wrappers live in Ruby where that does not affect the core benchmark paths.

## API

```ruby
hash = SwissHash::Hash.new(capacity = 16)

# Basic operations
hash[key] = value
hash.store(key, value)
hash[key]                  # returns nil if absent
hash.fetch(key)
hash.fetch(key, default)
hash.fetch(key) { |missing_key| ... }
hash.delete(key)           # returns old value or nil
hash.clear
hash.replace(other_hash)

# Merge/update
hash.merge(other_hash)
hash.merge(other_hash) { |key, old_value, new_value| ... }
hash.merge!(other_hash)
hash.update(other_hash)

# Enumeration
hash.each { |key, value| ... }
hash.each_pair { |key, value| ... }
hash.each_key { |key| ... }
hash.each_value { |value| ... }
hash.keys
hash.values
hash.to_a

# Query helpers
hash.size                  # also: length
hash.empty?
hash.key?(key)             # also: has_key?, include?, member?
hash.value?(value)         # also: has_value?
hash.key(value)            # first key for value, or nil
hash.assoc(key)
hash.rassoc(value)
hash.values_at(*keys)
hash.fetch_values(*keys)
hash.dig(key, *path)
hash.count                 # Enumerable-compatible

# Filtering and transforms
hash.slice(*keys)
hash.except(*keys)
hash.select { |key, value| ... }    # also: filter
hash.select! { |key, value| ... }   # also: filter!
hash.reject { |key, value| ... }
hash.reject! { |key, value| ... }
hash.delete_if { |key, value| ... }
hash.keep_if { |key, value| ... }
hash.compact
hash.compact!
hash.transform_keys { |key| ... }
hash.transform_keys! { |key| ... }
hash.transform_values { |value| ... }
hash.transform_values! { |value| ... }
hash.invert
hash.shift
hash.flatten(level = 1)

# Conversion
hash.to_h                  # returns a Ruby Hash
hash.to_sh                 # returns a shallow SwissHash copy

# Maintenance / debugging
hash.compact_storage!      # drop tombstones without changing values
hash.stats                 # => { capacity:, size:, num_groups:, load_factor:,
                           #      memory_bytes:, growth_left:, tombstones:,
                           #      simd:, layout: }
```

### Compatibility notes

SwissHash aims to cover the practical subset of `Hash` that is useful for a fast native hash map, but it is not a drop-in replacement for every Ruby Hash semantic.

Not currently supported:

- default values and default blocks from `Hash.new(default)` / `Hash.new { ... }`
- `compare_by_identity`
- full insertion-order guarantees
- every rarely used method from Ruby's full `Hash` API

## Usage Recommendations

Use SwissHash when:

- keys are mostly **strings** and insert speed matters;
- the map commonly holds **10,000+ entries**;
- workloads include deletes and reinserts;
- predictable native memory layout and lower Ruby-object churn are useful.

Stick with Ruby's built-in `Hash` when:

- the hash is small and mostly lookup-heavy with integer keys;
- you depend on exact Ruby Hash semantics such as defaults, insertion order, `compare_by_identity`, or the complete standard API;
- the code path benefits from VM-level `Hash#[]` specialization more than from the underlying table layout.

## Architecture

### Swiss Table core

- **Open addressing** with 7-bit `H2` metadata byte per slot; group matching rejects non-matching slots in batches.
- **Group size 16 on SSE2 (x86_64) and NEON (aarch64)**, **group size 8 on portable SWAR**. The active path is printed by `stats[:simd]` / the benchmark memory section (`NEON` on Apple Silicon).
- **Triangular probing** — `i(i+1)/2` — over power-of-two group counts.
- **Max load factor 87.5%** (7/8).

### Ruby-specific adaptations

- **wyhash** for string keys.
- **Fibonacci multiplicative hash** for Fixnum and Symbol keys.
- **Frozen string key preparation** to avoid later key mutation surprises.
- **ASCII-7bit and encoding-index equality fast paths** before falling back to Ruby-compatible string comparison.
- **Inline `RTYPEDDATA_DATA`** on hot methods (`[]`, `[]=`, `delete`, `key?`) to avoid repeated typed-data checks.
- **Prefetch of slot groups** after control-byte load so data fetch overlaps with match extraction.

### Memory layout

- One native allocation for control bytes followed by slots (16-byte aligned). `stats[:memory_bytes]` still counts `capacity * (1 + sizeof(Slot))`.
- Native arrays are allocated outside Ruby's object heap; keys and values are still marked for GC.
- Slot memory is not zero-initialized on allocation; slots are read only after their control byte marks them live.

## Build

```bash
bundle install
bundle exec rake compile
```

## Test

```bash
bundle exec ruby test/hash_api_test.rb
bundle exec ruby test/string_key_mutation_test.rb
bundle exec ruby test/safety_and_encoding_test.rb
```

## Benchmarking

```bash
bundle exec ruby benchmark.rb
```

The benchmark includes a smoke test before timing and prints the active SIMD/SWAR path in the memory section.

### Profiling

For profiling on macOS:

```bash
bundle exec ruby simp.rb            # runs an infinite lookup loop and prints PID
sample <PID> 60 -f /tmp/swiss.sample
filtercalltree /tmp/swiss.sample | head -100
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Design References

- Matt Kulukundis, ["Designing a Fast, Efficient, Cache-friendly Hash Table, Step by Step"](https://www.youtube.com/watch?v=ncHmEUmJZf4) — CppCon 2017
- [Abseil: SwissTables design](https://abseil.io/about/design/swisstables)
- [rust-lang/hashbrown](https://github.com/rust-lang/hashbrown) — reference for SSE2/portable group strategy choices
- [Go 1.24 maps](https://go.dev/blog/swisstable) — probing and resize design trade-offs
- Aria Beingessner, ["Swisstable, a Quick and Dirty Description"](https://faultlore.com/blah/hashbrown-tldr/) — implementer's notes

## License

MIT
