# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0]

### Added

- `dart run avro:generate <schemas…> -o <file>` generates immutable Dart classes for the records of `.avsc` files, with value equality, `copyWith` and an `avroType` for `TypedCodec`, and Dart enums for Avro enums, each value with its `symbol`.
- `TypedCodec<T>` encodes and decodes Dart classes described by an `AvroType<T>` (the schema text, `toAvro` and `fromAvro`), with the resolution and single-object encoding of `AvroCodec`.
- `DecodeException.blockOffset` says where in a container file the block of a failing record starts; `offset` counts inside the decompressed block.

### Changed

- `AvroFileReader.records(codec)` rejects a codec whose writer schema is not the file's, with `DecodeException` naming both fingerprints, before it decodes a record.
- A writer value read as a reader union takes the branch Apache Avro's Java implementation takes: the same type or full name first, then a record that resolves, then a promotion. An `int` read as `["null", "double", "int"]` now stays an `int`.
- Every limit of `AvroLimits` throws `LimitExceededException`: a value nested deeper than `maxValueDepth` on encode, and a container block with more zero-size records than `maxZeroSizeItems`, no longer throw `EncodeException` and `DecodeException`.

### Fixed

- A string that is not a UUID, encoded as the logical type `uuid`, fails with `"…" is not a UUID` instead of "expected a UUID String for uuid, got String".
- The API documentation of `AvroLimits.maxZeroSizeItems` says it bounds arrays and container blocks, not maps.

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
