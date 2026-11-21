# 4. Container files in memory, and limits that are on by default

Date: 2026-11-21

## Status

Accepted.

## Context

The package decodes bytes from untrusted senders. A small deflated block can expand without bound, and declared lengths and counts in Avro data come before their content. AXT limits a file to 256 MiB as stored and 1 GiB decompressed; a message is at most 16 MiB (`spec/envelope.md`, section 8). AXT reads a file's header and checks its signature before it decodes any record, decodes with its own copy of the envelope schema rather than the file's, and publishes a byte-exact example file (section 10.3).

## Decision

- I/O is synchronous over `Uint8List`. `AvroFileReader(bytes, limits:)` exposes the header: the metadata in file order as `Uint8List` values, the `avro.schema` text, the compression and the sync marker. `records(codec)` returns a lazy `Iterable` that decompresses one block at a time with the codec the caller passes; `records()` alone uses the file's own schema.
- `AvroFileWriter(codec, compression:, metadata:, syncMarker:, schemaJson:)` writes incrementally with `add`, `flush` (ends the current block) and `close` (returns the file). A block also ends on its own at a target size. `schemaJson` defaults to the codec's writer schema text and is written exactly as given; `syncMarker` defaults to random bytes.
- The writer puts the caller's metadata first, in the caller's order, then `avro.codec` (always, `null` included), then `avro.schema`. A caller key starting with `avro.` throws. This is the order of AXT's example file in `spec/envelope.md`, section 10.3, which fastavro 1.13.1 wrote.
- One `AvroLimits` object configures the codec, the schema parser and the container reader. Its defaults are finite: 64 MiB per decompressed block, 1 GiB decompressed per file, 1 MiB per schema and a nesting depth of 64. `AvroLimits.none` opts out. The reader stops decompressing as soon as a limit is exceeded.
- Always on, whatever the limits: a declared length or count is checked against the remaining input before anything is allocated, negative lengths are rejected, and strings must be well-formed UTF-8, surrogate code points included.

## Considered options

- Asynchronous streams: the compressed file would never have to be in memory, but 256 MiB fits on a phone, and synchronous code is simpler to test. Stream adapters can be added later on top.
- No limits in the package: a caller cannot stop decompression in the middle of a block.
- Unlimited by default: the fuzz target would hit a deflate bomb on the first day.

## Consequences

- A file is held in memory whole while it is read; only its decompressed records are bounded to one block.
- A caller with stricter needs, such as AXT, declares its own `AvroLimits` constant.
