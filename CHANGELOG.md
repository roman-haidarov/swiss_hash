# Changelog

## 0.1.3 - 2026-08-18

- NEON group matching on ARM64 (SSE2 on x86_64, SWAR elsewhere)
- Single allocation for control bytes and slots
- Faster Fixnum `[]` / `[]=`
- 7-bit strings of different encodings hash like Ruby Hash (`"abc"` and `"abc".b` are the same key)
- Rehash is GC-safe; `#hash` / `#eql?` that mutate the same table raise instead of corrupting it
- `initialize` no longer leaks on reuse; OOM no longer leaves a half-built table

## 0.1.2 - Unreleased

Documentation and API polish for the first public release candidate.

### Added / changed

- Expanded the Hash-like API surface:
  - `fetch`, `values_at`, `fetch_values`
  - `merge`, `merge!`, `update`, `replace`
  - `to_h`, `to_sh`, `to_a`
  - `slice`, `except`, `invert`, `assoc`, `rassoc`, `shift`
  - `delete_if`, `keep_if`, `select`, `select!`, `filter`, `filter!`, `reject`, `reject!`
  - `compact`, `compact!`, `transform_keys`, `transform_keys!`, `transform_values`, `transform_values!`
  - `value?`, `has_value?`, `key`, `dig`, `count`, `flatten`, `==`, `eql?`, `hash`, `inspect`
- Moved the important Hash-like operations into the C extension instead of doing the expensive parts in Ruby.
- Kept `to_h` as the Ruby-compatible conversion to a real `Hash`; added `to_sh` as the explicit shallow SwissHash copy.
- Updated the README with the latest benchmark output from Ruby 3.4.3 / arm64-darwin24.
- Documented compatibility boundaries: no default values/default blocks, no `compare_by_identity`, no full insertion-order guarantee, and not the entire Ruby `Hash` API yet.

### Benchmark update

Struck-through values are the previous README numbers. The value after the arrow is the current benchmark result.

#### N = 100,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (string keys) | ~~17.6 ms~~ → 16.485 ms | ~~11.3 ms~~ → 10.386 ms | ~~−35.8%~~ → **−37.00%** |
| Delete + reinsert 25% | ~~9.8 ms~~ → 8.965 ms | ~~8.9 ms~~ → 7.164 ms | ~~−9.0%~~ → **−20.09%** |
| Insert (sequential int) | ~~7.0 ms~~ → 6.324 ms | ~~6.4 ms~~ → 5.023 ms | ~~−8.7%~~ → **−20.57%** |
| Mixed (70/20/10 R/W/D) | ~~21.4 ms~~ → 21.784 ms | ~~19.6 ms~~ → 18.990 ms | ~~−8.6%~~ → **−12.83%** |
| Insert (random int) | ~~6.7 ms~~ → 5.963 ms | ~~6.4 ms~~ → 5.010 ms | ~~−3.5%~~ → **−15.98%** |
| Lookup (string keys, 3x) | ~~20.3 ms~~ → 20.561 ms | ~~20.8 ms~~ → 21.535 ms | ~~+2.5%~~ → +4.74% |
| Lookup (sequential int, 3x) | ~~11.7 ms~~ → 13.281 ms | ~~12.2 ms~~ → 11.116 ms | ~~+4.4%~~ → **−16.31%** |

#### N = 10,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (string keys) | ~~1.63 ms~~ → 1.522 ms | ~~1.10 ms~~ → 0.992 ms | ~~−32.8%~~ → **−34.80%** |
| Lookup (string keys, 3x) | ~~1.71 ms~~ → 1.710 ms | ~~1.62 ms~~ → 1.563 ms | ~~−5.2%~~ → **−8.58%** |
| Mixed (70/20/10 R/W/D) | ~~1.93 ms~~ → 1.988 ms | ~~1.90 ms~~ → 1.869 ms | ~~−1.6%~~ → **−5.98%** |
| Delete + reinsert 25% | ~~0.91 ms~~ → 0.814 ms | ~~0.89 ms~~ → 0.714 ms | ~~−2.0%~~ → **−12.29%** |
| Insert (sequential int) | ~~0.66 ms~~ → 0.578 ms | ~~0.67 ms~~ → 0.510 ms | ~~+2.5%~~ → **−11.82%** |
| Lookup (sequential int, 3x) | ~~1.05 ms~~ → 1.071 ms | ~~1.12 ms~~ → 1.065 ms | ~~+6.0%~~ → −0.55% |
| Insert (random int) | previously not listed → 0.554 ms | previously not listed → 0.501 ms | **−9.53%** |

#### N = 1,000

| Operation | Ruby Hash | SwissHash | Delta |
|---|---:|---:|---:|
| Insert (string keys) | ~~0.183 ms~~ → 0.156 ms | ~~0.118 ms~~ → 0.102 ms | ~~−35.6%~~ → **−34.78%** |
| Lookup (string keys, 3x) | ~~0.184 ms~~ → 0.181 ms | ~~0.155 ms~~ → 0.150 ms | ~~−15.5%~~ → **−17.10%** |
| Insert (sequential int) | ~~0.063 ms~~ → 0.056 ms | ~~0.074 ms~~ → 0.057 ms | ~~+17.5%~~ → +1.88% |
| Delete + reinsert 25% | ~~0.094 ms~~ → 0.082 ms | ~~0.102 ms~~ → 0.079 ms | ~~+8.2%~~ → −4.12% |
| Insert (random int) | previously not listed → 0.054 ms | previously not listed → 0.051 ms | −6.54% |
| Lookup (sequential int, 3x) | previously not listed → 0.111 ms | previously not listed → 0.111 ms | +0.29% |
| Mixed (70/20/10 R/W/D) | previously not listed → 0.202 ms | previously not listed → 0.197 ms | −2.04% |

### Memory update

| Metric | Previous README | Current benchmark |
|---|---:|---:|
| SwissHash native memory, N=100,000 | ~~2,176 KB + 4 GC slots~~ | 2,176 KB native + 4 GC slots |
| Ruby Hash | ~~managed via GC slots / not directly measurable~~ | 3 GC slots; native memory not directly measurable |
| Load factor | ~~76.3%~~ | 76.3% |
| SIMD path | not shown in table | SWAR |

## 0.1.1 and earlier

Pre-release iterations focused on the initial Swiss Table C extension, Ruby object/GC integration, string-key fast paths, deletion/tombstone handling, and the first benchmark harness.
