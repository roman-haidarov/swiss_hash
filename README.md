# SwissHash

Swiss Table hash map implementation as a Ruby C extension. Based on Go 1.24 Swiss Table design with SIMD support (SSE2/NEON).

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

Benchmarks on Ruby 3.1.7 / arm64-darwin24 with NEON SIMD support (median of 3 runs):

### Insert Performance
- **String keys**: SwissHash is **18.9-28.6% faster** across all dataset sizes
- **Sequential integers**: 24.6% slower (1k), 3.7% slower (10k), **11.5% faster** (100k)
- **Random integers**: 11.6% slower (1k), 4.7% slower (10k), **6.3% faster** (100k)

### Lookup Performance
- **Sequential integers**: SwissHash is **7.3-10.6% slower** across all sizes
- **String keys**: SwissHash is **13.0-25.2% slower** across all sizes

### Mixed Workloads
- **Delete+reinsert (25%)**: 9.1% slower (1k), 2.5% slower (10k), **13.5% faster** (100k)
- **Mixed operations (70% read, 20% write, 10% delete)**: 2.0% slower (1k), 0.5% faster (10k), **11.6% faster** (100k)

### Memory Usage
For 100,000 elements:
- **SwissHash**: 2,176 KB native memory + 4 GC slots
- **Ruby Hash**: 3 GC slots (native memory not directly measurable)
- **Load factor**: 76.3% (efficient memory usage)
- **GC pressure**: Equal (0 GC runs during insertion)

## Features

- **SIMD optimized**: Uses SSE2 on x86_64 and NEON on ARM64
- **Memory efficient**: Swiss Table layout with 87.5% max load factor
- **Tombstone compaction**: Automatic cleanup of deleted entries
- **Ruby compatibility**: Supports frozen string keys, all Ruby object types
- **Thread safety**: Prevents reentrant modifications during callbacks

## API

```ruby
hash = SwissHash::Hash.new(capacity = 16)

# Basic operations
hash[key] = value
hash[key]          # get
hash.delete(key)   # delete, returns old value or nil

# Enumeration
hash.each { |k, v| ... }
hash.keys
hash.values

# Size and status
hash.size
hash.empty?
hash.key?(key)

# Maintenance
hash.clear
hash.compact!      # remove tombstones

# Debugging
hash.stats         # => detailed statistics hash
```

## Usage Recommendations

SwissHash shows clear advantages in specific scenarios:
- **Heavy string key insertion** into any size hash table (consistent 19-29% improvement)
- **Large dataset operations** (>100k elements) - shows improvements across most operations
- **Write-heavy workloads** with frequent deletion and reinsertion patterns
- **Cases where predictable memory usage is important**

⚠️ **Important**: SwissHash is consistently **7-25% slower for all lookup operations**. For read-intensive applications, stick with standard Ruby Hash.

## Technical Analysis: Why Ruby Hash is Faster for Lookups

The performance difference in lookup operations comes from several architectural factors:

### Ruby VM Optimizations
- **Specialized fast paths**: Ruby VM has highly optimized inline implementations for common key types (Fixnum, Symbol, String)
- **Method caching**: VM-level inline caching for hash access patterns reduces method dispatch overhead
- **Bytecode optimizations**: Hash access is optimized at the bytecode level with specialized opcodes
- **Memory locality**: Ruby Hash uses a simpler layout optimized for CPU cache performance

### SwissHash Overhead
- **C Extension boundaries**: Each lookup requires `TypedData_Get_Struct()` call and Ruby-C interface overhead
- **Complex hash computation**: SwissHash uses sophisticated hashing (wyhash for strings, custom mixers) vs Ruby's simpler approach
- **Two-level lookup**: Swiss Table's H1/H2 split requires additional bit manipulation and SIMD operations
- **SIMD overhead**: NEON/SSE2 operations have setup costs that don't pay off for small group scans
- **Additional equality checks**: `keys_equal()` function adds extra indirection compared to VM's direct comparison

### Architecture Trade-offs
- **Swiss Table design**: Optimized for high load factors and cache efficiency, but adds complexity to the critical lookup path  
- **Group-based probing**: While theoretically faster, the overhead of SIMD operations and multiple memory accesses hurts performance for typical Ruby workloads
- **Memory indirection**: SwissHash's separate control bytes array creates additional memory accesses vs Ruby Hash's integrated approach

This explains why SwissHash excels at write-heavy operations (where its design advantages matter) but loses to Ruby's VM-optimized lookups.

## Build

```
rake compile
```

## Analysis Tools

Project includes comprehensive benchmark with statistical validation:

```bash
ruby -Ilib benchmark.rb
```

The benchmark measures (with 7 iterations, 2 warmup, GC disabled):
- Insert performance (sequential int, strings, random int)
- Lookup performance (with 3x repetition for signal amplification)
- Delete with reinsertion operations  
- Mixed workloads (70/20/10 read/write/delete)
- Memory usage and GC pressure analysis

Results are statistically validated through multiple runs to ensure accuracy.

## License

MIT
