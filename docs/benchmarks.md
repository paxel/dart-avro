# Benchmarks

The baseline of the benchmark suite of [avro-1036](https://github.com/paxel/dart-avro/issues/41)
(ADR 11): the package on the Dart AOT build, next to Apache Avro for Java (generic reader and
writer, warmed up) and fastavro, on the same schemas and the same values. The target of
[avro-1037](https://github.com/paxel/dart-avro/issues/42) is binary encode and decode of records
within 2× of Java.

## Machine and versions

| What           | Value                                                                            |
|----------------|----------------------------------------------------------------------------------|
| CPU            | Intel Core i7-9750H @ 2.60 GHz (up to 4.5 GHz), 6 cores, 12 threads              |
| RAM            | 62 GiB                                                                           |
| OS             | Debian GNU/Linux 13 (trixie), kernel 7.0.0-113043-tuxedo                         |
| Dart           | 3.14.0 (stable), AOT (`dart compile exe`), `benchmark_harness` 2.4.0             |
| Java           | GraalVM CE 21.0.2+13.1 (Graal JIT, not stock HotSpot), Maven 3.9.16              |
| Apache Avro    | 1.12.1, with jackson 2.21.7, snappy-java 1.1.10.9 and zstd-jni 1.5.7-4           |
| fastavro       | 1.13.1 (its Cython modules), Python 3.13.5, cramjam 2.14.0, backports.zstd 1.8.0 |
| Package        | `avro` 0.4.0 at 6c79f24, before the plan of avro-1037                            |

Each program ran once, alone, under `nice -n 19`, on 2026-11-22.

The Java project pins jackson (through `jackson-bom`) and snappy-java above the versions avro
1.12.1 brings, 2.20.0 and 1.1.10.8: OSV lists 16 advisories against those jackson versions and 3
against that snappy-java. 2.21.7 and 1.1.10.9 are the lowest versions that fix them all; the
resolved set had no open advisory on api.osv.dev on 2026-11-22.

## Commands

From the repository root:

```sh
# Dart, compiled ahead of time
dart compile exe tool/bench/bench.dart -o /tmp/bench
nice -n 19 /tmp/bench --json dart.json

# Java
(cd tool/bench/java && mvn -q -T1 package dependency:copy-dependencies)
nice -n 19 java -cp 'tool/bench/java/target/classes:tool/bench/java/target/dependency/*' \
  bench.Bench --json java.json

# fastavro
python3 -m venv /tmp/venv
/tmp/venv/bin/pip install 'fastavro[snappy,zstandard]==1.13.1'
nice -n 19 /tmp/venv/bin/python tool/bench/fastavro_bench.py --json fastavro.json
```

Each prints a table of ops/s, µs/op and the size of the encoding per case; `--json` also
writes it to a file.

## Cases

Every workload is encoded (`encode`), decoded with the writer schema (`decode`), and decoded
with a reader schema that differs (`resolve`). The schemas are files that all three programs
load; the values are built by the same rules on every side, and their encodings were checked to
be byte for byte the same in all three.

| Workload   | Writer schema                            | Value                                    | Reader schema of `resolve`                                                                      |
|------------|------------------------------------------|------------------------------------------|-------------------------------------------------------------------------------------------------|
| `interop`  | `test/data/apache/interop.avsc`          | one record, nested `Node`, 103 bytes     | `tool/bench/schemas/interop-reader.avsc`: `int` and `float` promoted, a field dropped and added |
| `envelope` | `test/data/axt/types/axt/Envelope.avsc`  | the envelope of `memo-message.hex`       | `envelope-reader.avsc`: `format` as `long`, a field `note` added                                |
| `wide`     | `tool/bench/schemas/wide.avsc`           | 50 fields of 10 kinds, 234 bytes         | `wide-reader.avsc`: the fields in reverse order, `int` and `float` promoted                     |
| `longs`    | `tool/bench/schemas/longs.avsc`          | an array of 10,000 longs, 59,691 bytes   | `longs-reader.avsc`: an array of `double`                                                       |

- **Values.** `interop`: the record in `interopValue()` of `tool/bench/bench.dart`, with a
  one-entry map. `wide`, record `r`: field `f<i>` is of kind `i % 10` (`int`, `long`, `string`,
  `double`, `boolean`, `float`, `bytes`, `["null","string"]`, `["null","long"]`, enum `Color`),
  its value made from `n = i + r`. `longs`: element `j` is
  `(j * 2654435761) % 2^40 - 2^39`.
- **JSON.** `json/<workload>/encode` and `decode`: Avro's JSON encoding of the `interop` and
  `wide` values.
- **Container files.** `file/<compression>/write` and `read`: 1,000 `wide` records, `r` from 0
  to 999, in memory, with blocks of 64 KiB before compression and a fixed sync marker.
  `deflate` at level 6 and `zstandard` at level 3 on every side; Java and Dart write a zstd
  checksum, fastavro does not.
- **Generated classes.** `typed/envelope/encode` and `decode`: `TypedCodec` with `AxtEnvelope`
  of `test/data/axt/axt_types.g.dart`. Java would need its own code generator and fastavro has
  none, so they have no such case.

How each side measures:

- **Dart:** `benchmark_harness`, 100 ms of warm-up, then at least 2 s timed, one operation per
  measured call.
- **Java:** 2 s of warm-up for the JIT, then at least 2 s timed. Encoding reuses its
  `BinaryEncoder` and output stream but returns a fresh `byte[]`; decoding reuses its
  `BinaryDecoder` but no record, and keeps the result without walking it. The generic reader
  decodes strings as Avro's lazy `Utf8`, its default; this package decodes them into Dart
  `String`s, which costs more. The envelope's `Utf8` id is turned into a `String` before it is
  encoded, as the other sides encode it.
- **fastavro:** 1 s of warm-up, then at least 2 s timed.
- **Not the same everywhere:**
  - fastavro's JSON encoder recurses without end on the recursive `Node` of `interop.avsc`, so
    it has no `json/interop` cases.
  - Its JSON escapes more characters, hence the larger size.
  - The container files have the same 4 blocks on every side, but their headers differ: this
    package writes the schema's text as the file has it, indented (3,424 bytes of header), Java
    and fastavro a compact form (1,763 and 2,001 bytes). The compressed blocks also differ a
    little, as each side has its own compressor.

## Results

µs per operation, lower is better. `Dart ÷ Java` is how many times longer the Dart operation
takes. The 2× target of [avro-1037](https://github.com/paxel/dart-avro/issues/42) is on binary
`encode` and `decode` of the three record workloads.

| Case                    | Dart µs/op | Java µs/op | fastavro µs/op | Dart ÷ Java | 2× target |
|-------------------------|-----------:|-----------:|---------------:|------------:|-----------|
| `interop/encode`        |      5.187 |      0.547 |         11.537 |        9.5× | not met   |
| `interop/decode`        |      4.504 |      0.438 |          7.499 |       10.3× | not met   |
| `interop/resolve`       |      5.973 |      0.512 |         20.260 |       11.7× |           |
| `envelope/encode`       |      3.401 |      0.235 |         10.807 |       14.4× | not met   |
| `envelope/decode`       |      2.269 |      0.186 |          4.642 |       12.2× | not met   |
| `envelope/resolve`      |      2.985 |      0.193 |         11.534 |       15.5× |           |
| `wide/encode`           |     16.062 |      1.188 |         24.765 |       13.5× | not met   |
| `wide/decode`           |      9.809 |      0.971 |         16.830 |       10.1× | not met   |
| `wide/resolve`          |     14.755 |      0.992 |         42.432 |       14.9× |           |
| `longs/encode`          |      1,381 |        127 |          2,229 |       10.9× |           |
| `longs/decode`          |      1,541 |        130 |          2,453 |       11.8× |           |
| `longs/resolve`         |      1,833 |        115 |          5,243 |       15.9× |           |
| `json/interop/encode`   |     13.636 |      3.359 |            n/a |        4.1× |           |
| `json/interop/decode`   |     14.744 |      4.854 |            n/a |        3.0× |           |
| `json/wide/encode`      |     38.077 |      5.811 |            279 |        6.6× |           |
| `json/wide/decode`      |     35.350 |      9.970 |            220 |        3.5× |           |
| `file/null/write`       |     16,563 |      1,970 |         24,932 |        8.4× |           |
| `file/null/read`        |     10,469 |      1,128 |         17,373 |        9.3× |           |
| `file/deflate/write`    |     19,312 |      4,879 |         28,384 |        4.0× |           |
| `file/deflate/read`     |     11,341 |      1,621 |         17,689 |        7.0× |           |
| `file/snappy/write`     |     17,997 |      2,065 |         25,221 |        8.7× |           |
| `file/snappy/read`      |     12,159 |      1,254 |         17,600 |        9.7× |           |
| `file/zstandard/write`  |     19,316 |      2,469 |         31,533 |        7.8× |           |
| `file/zstandard/read`   |     10,988 |      1,405 |         21,059 |        7.8× |           |
| `typed/envelope/encode` |      4.392 |        n/a |            n/a |         n/a |           |
| `typed/envelope/decode` |      3.046 |        n/a |            n/a |         n/a |           |

Before [avro-1037](https://github.com/paxel/dart-avro/issues/42), binary record encode and
decode take 9.5× to 14.4× as long as Java's, and are faster than fastavro's in every case. The
`longs` workload, about 140 ns per element, shows the cost per value most plainly. The Java
numbers vary between runs by up to 2× in single cases (`wide/resolve` took 1.0 µs in this run
and 2.2 µs in an earlier one); the table is one run.
