# 2. One codec per schema pair, with generic values

Date: 2026-11-21

## Status

Accepted.

## Context

Avro libraries in other languages expose several types for one round trip: Java's `DatumWriter`, `DatumReader`, `Encoder` and `Decoder`. AXT resolves a writer schema against its reader schema once and then decodes many records with that resolution (`spec/envelope.md`, section 6), and it shows records of types it does not know from their schema alone (`spec/types.md`, section 6).

## Decision

- The interface is a single `AvroCodec(writer:, reader:)`. `reader` defaults to `writer`. The constructor compiles the resolution and throws `ResolutionException` if the schemas do not resolve; `encode` always writes with the writer schema.
- `decode` throws `DecodeException` on bytes left over after the datum. There is no variant for datums written back to back.
- Single-object encoding is `codec.encodeSingleObject` and `codec.decodeSingleObject`, plus `SingleObjectHeader.parse(bytes)`, so a caller can read the fingerprint and choose the codec first. Which fingerprints a caller accepts is not the package's concern.
- Values are generic: records and maps are `Map<String, Object?>`, arrays `List<Object?>`, enums `String`, `bytes` and `fixed` `Uint8List`. Code generation of typed classes is planned as a later minor version (ADR 1).
- `encode` is strict about records: a missing field throws `EncodeException` even when it has a default, and so does a key that names no field. Defaults serve schema resolution only, as in the Avro specification.
- A union branch is inferred when exactly one branch fits the value; otherwise the caller wraps the value as `Branch(name, value)`, and an ambiguous value without one throws, naming the candidate branches. `decode` returns the plain value.
- `Schema.parse` returns a public, immutable `sealed` tree that keeps `doc`, `aliases`, `logicalType`, the custom attributes (`props`, on types and on fields) and the original JSON text. There are no schema builders.
- The CRC-64-AVRO fingerprint is an `int` holding the 64-bit pattern, as Java's `long` does, with helpers to and from 8 little-endian bytes; MD5 and SHA-256 are `Uint8List`.
- Failures are a `sealed class AvroException` with one subtype per cause: `SchemaParseException`, `ResolutionException`, `DecodeException`, `EncodeException`, `LimitExceededException` and `UnsupportedCompressionException`.
- The package has one public library, `package:avro/avro.dart`.

## Considered options

- Methods on `Schema` plus a separate resolver object: resolving once would be an extra step callers could skip.
- Always inferring union branches, as Python `avro` does: it silently picks the wrong record when two fit.
- Always requiring `Branch`: even `["null", "string"]`, by far the most common union, would need wrapping.
- A `Fingerprint` value class: an `int` is already a free map key, and the CRC is the only fingerprint used for lookups.

## Consequences

- A union of two records cannot be told apart after decoding. Returning `Branch` from `decode` can be added later as a codec option without breaking callers.
- In this package, "codec" means the `AvroCodec` object only. What the Avro specification calls a file's codec (`null`, `deflate`) is called compression in every name and text: `compression:`, `header.compression`, `UnsupportedCompressionException`. Only the metadata key keeps the specification's name, `avro.codec`.
