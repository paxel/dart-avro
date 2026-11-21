# 9. The optional compressions, JSON encoding and streamed container files

Date: 2026-11-21

## Status

Accepted. Extends ADR 1 (scope) and ADR 4 (container files and limits).

## Context

0.1 and 0.2 read and write only the binary encoding and container files compressed with `null` or `deflate`, held in memory as a whole. Files written by other ecosystems often use `snappy`, `zstandard`, `bzip2` or `xz`. The JSON encoding of Avro is what tools show and exchange for debugging. Large container files should not have to sit in memory.

The pure-Dart package `archive` (MIT, version 4.7.1) provides bzip2, xz and zstd; no Dart package provides Snappy. Apache Avro's Java implementation writes a union branch in JSON by its full name (`ValidatingGrammarGenerator`, tag `release-1.12.2`) and floats through Jackson's `writeNumber`.

## Decision

- **Compressions.** Container files are read and written with `snappy`, `bzip2`, `xz` and `zstandard` as well, all in pure Dart:
  - `bzip2`, `xz` and `zstandard` through `archive`, the one new dependency
  - `snappy` in this package, with the big-endian CRC32 of the uncompressed block that Avro appends to each Snappy block
  - A compression that `archive` can only decode is read-only; writing with it throws `UnsupportedCompressionException`.
  - The writer's `compression:` takes the Avro names.
- **Limits.** The block and total limits of ADR 4 stop decompression as soon as they are exceeded, for every compression, through an output that counts. A decoder that cannot be stopped that way is not offered for reading. `maxBlockBytes` also bounds a block's compressed size in the stream reader.
- **JSON encoding.**
  - `AvroCodec` and `TypedCodec` gain `encodeJson` (a `String`, compact, with an optional `indent:`) and `decodeJson`. Decoding resolves from the writer to the reader schema, as for binary.
  - A union value is `null` or `{"<branch>": value}`. The branch is the full name for a named type and the type name otherwise, as Java writes it. `decodeJson` also accepts a branch's simple name where it is unambiguous in that union.
  - `NaN` and the infinities are written as the strings `"NaN"`, `"Infinity"` and `"-Infinity"`, and read back from them.
  - Errors are the existing `EncodeException` and `DecodeException`; a JSON position is given as a path.
- **Streams.**
  - `AvroFileStreamReader.open(Stream<List<int>>, {limits})` returns a `Future` once the header is read. `records([codec])` is a `Stream` of records, with the same codec check as `AvroFileReader`.
  - `AvroFileStreamWriter(codec, StreamSink<List<int>>, …)` writes with `add` and `flush`; its `close()` returns a `Future`.
  - One block is held in memory at a time.

## Considered options

- Native libraries through FFI: faster, but native binaries on every platform, against the pure-Dart scope of ADR 1.
- Only `snappy` and `zstandard`: the most common, but `bzip2` and `xz` cost no more once `archive` is a dependency.
- A separate `AvroJsonCodec`: a second type to learn, and resolution compiled twice.
- Writing the simple name, or rejecting non-finite floats in JSON: less compatible with Java.

## Consequences

- `avro` depends on `archive` and, through it, on `path` and `posix`.
- An Avro file from Java, Python, Spark or Kafka is readable whatever its required or optional compression.
