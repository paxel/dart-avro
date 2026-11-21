# 8. One exception per limit, checked file schemas, and Java's reader-union order

Date: 2026-11-21

## Status

Accepted. Changes ADR 4 (container files and limits) and the resolution of ADR 2.

## Context

After 0.1.x, several behaviours were inconsistent or surprising:

- **Depth:** `maxValueDepth` threw `LimitExceededException` on decode but `EncodeException` on encode.
- **Zero-size records:** too many of them in a container block threw `DecodeException`, while the codec threw `LimitExceededException` for the same limit.
- **Unchecked codec:** `AvroFileReader.records(codec)` accepted a codec of any writer schema.
- **Error position:** a `DecodeException` from a record counted its offset from the start of the decompressed block, which with `deflate` exists only in memory.
- **Reader unions:** a reader union took the first branch that matched, promotions included, so an `int` read as `["null", "double", "long"]` became `5.0`.

Apache Avro's Java `Resolver.firstMatchingBranch` (tag `release-1.12.2`) instead takes:

1. an exact type or full-name match first
2. then a record that resolves structurally, preferring the same short name
3. then a promotion

Its comment calls this a "soft match" that "seems to disagree with the spec", kept for compatibility.

## Decision

- **One exception per limit.** Every limit of `AvroLimits` throws `LimitExceededException` naming the limit, whatever the direction. Exceeding `maxValueDepth` while encoding is no longer an `EncodeException`, and too many zero-size records in a container block are no longer a `DecodeException`.
- **Checked writer schema.** `records(codec)` compares the canonical form of `codec.writer` with the file's `avro.schema` before it decodes a record. A mismatch throws `DecodeException` naming both fingerprints. To read a file as another schema, the codec's writer is the file's schema and its reader the caller's.
- **Both error positions.** `DecodeException` gains a nullable `blockOffset`: the file offset where the block starts. `offset` stays inside the decompressed block, and `toString` shows both.
- **Java's union order.** A reader union takes the branch Java takes: exact type or full name, then a structurally resolving record, then a promotion.

## Consequences

- These are breaking changes in behaviour, released in 0.2.0 while the package has no other user than `axt_protocol`.
- Data written by any implementation resolves into the same reader branch in Dart as in Java.
