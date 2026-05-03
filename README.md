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
| Insert (sequential int) | 6.324 ms (±0.5%) | 5.023 ms (±0.6%) | **−20.57%** ⚡ |
| Insert (string keys) | 16.485 ms (±4.6%) | 10.386 ms (±3.0%) | **−37.00%** ⚡ |
| Insert (random int) | 5.963 ms (±1.2%) | 5.010 ms (±1.0%) | **−15.98%** ⚡ |
| Lookup (sequential int, 3x) | 13.281 ms (±0.1%) | 11.116 ms (±0.1%) | **−16.31%** ⚡ |
| Lookup (string keys, 3x) | 20.561 ms (±3.8%) | 21.535 ms (±4.9%) | +4.74% |
| Delete + reinsert 25% | 8.965 ms (±0.7%) | 7.164 ms (±0.8%) | **−20.09%** ⚡ |
| Mixed (70% read / 20% write / 10% delete) | 21.784 ms (±0.2%) | 18.990 ms (±0.3%) | **−12.83%** ⚡ |

### N = 10,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (sequential int) | 0.578 ms (±1.1%) | 0.510 ms (±1.1%) | **−11.82%** ⚡ |
| Insert (string keys) | 1.522 ms (±3.5%) | 0.992 ms (±1.6%) | **−34.80%** ⚡ |
| Insert (random int) | 0.554 ms (±2.0%) | 0.501 ms (±2.5%) | **−9.53%** ⚡ |
| Lookup (sequential int, 3x) | 1.071 ms (±0.3%) | 1.065 ms (±0.1%) | −0.55% |
| Lookup (string keys, 3x) | 1.710 ms (±1.3%) | 1.563 ms (±1.4%) | **−8.58%** ⚡ |
| Delete + reinsert 25% | 0.814 ms (±1.6%) | 0.714 ms (±1.2%) | **−12.29%** ⚡ |
| Mixed (70% read / 20% write / 10% delete) | 1.988 ms (±0.4%) | 1.869 ms (±0.5%) | **−5.98%** ⚡ |

### N = 1,000

Ruby Hash uses an AR-table for small hashes, so very small integer-keyed workloads can still favour the built-in implementation. String-heavy workloads continue to be the strongest SwissHash case.

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (sequential int) | 0.056 ms (±0.7%) | 0.057 ms (±0.9%) | +1.88% |
| Insert (string keys) | 0.156 ms (±2.5%) | 0.102 ms (±0.9%) | **−34.78%** ⚡ |
| Insert (random int) | 0.054 ms (±3.5%) | 0.051 ms (±3.4%) | −6.54% |
| Lookup (sequential int, 3x) | 0.111 ms (±0.4%) | 0.111 ms (±0.2%) | +0.29% |
| Lookup (string keys, 3x) | 0.181 ms (±0.3%) | 0.150 ms (±0.4%) | **−17.10%** ⚡ |
| Delete + reinsert 25% | 0.082 ms (±0.9%) | 0.079 ms (±0.5%) | −4.12% |
| Mixed (70% read / 20% write / 10% delete) | 0.202 ms (±0.3%) | 0.197 ms (±0.2%) | −2.04% |

### Summary

- SwissHash is faster on **6 of 7 operations** at N=100k in the current benchmark run.
- The strongest win is still string-key insertion: **−34% to −37%** across tested sizes.
- Large integer-keyed inserts, delete/reinsert churn, and mixed workloads improved substantially after moving more Hash-like operations into C and keeping the hot paths lean.
- String lookups are workload-sensitive: SwissHash wins at N=1k and N=10k, while the N=100k run is slightly slower than Ruby Hash within a noisier test band.
- Ruby's built-in `Hash` remains excellent, especially for very small maps and cases that benefit from VM-level Hash specialization.

### Memory Usage

For 100,000 integer keys in the current benchmark:

| Implementation | Reported memory |
|---|---:|
| SwissHash | 2,176 KB native + 4 GC slots |
| Ruby Hash | 3 GC slots; native memory not directly measurable from this benchmark |

Additional stats: load factor 76.3%, max load factor 87.5%, SIMD path reported as SWAR on the benchmark machine.

## Features

- **Swiss Table probing**: 7-bit `H2` metadata, group probing, triangular probe sequence, and 87.5% max load factor.
- **Fast string-key path**: wyhash for string keys, frozen string key preparation, ASCII-7bit equality shortcut, and direct `memcmp` when encodings are compatible.
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
- **Group size 16 on SSE2** and **group size 8 on portable SWAR**. On the benchmarked Apple Silicon machine the active path is SWAR.
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

- Separate control-byte array and slot array.
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
