# Older changes

Released versions before the current one, newest first.

## [0.2.0] - 2026-11-21

### Added

- The docs site has a Guide page on code generation and `TypedCodec`, and What's new describes 0.2.0 ([avro-1024](https://github.com/paxel/dart-avro/issues/27)).
- `dart run avro:generate <schemas…> -o <file>` generates immutable Dart classes for the records of `.avsc` files, with value equality, `copyWith` and an `avroType` for `TypedCodec`, and Dart enums for Avro enums, each value with its `symbol`. A type defined in several files becomes one Dart type, and `--prefix <namespace>=<Prefix>` names the types of a namespace ([avro-1020](https://github.com/paxel/dart-avro/issues/23), [avro-1021](https://github.com/paxel/dart-avro/issues/24), [avro-1022](https://github.com/paxel/dart-avro/issues/25)).
- `TypedCodec<T>` encodes and decodes Dart classes described by an `AvroType<T>` (the schema text, `toAvro` and `fromAvro`), with the resolution and single-object encoding of `AvroCodec` ([avro-1019](https://github.com/paxel/dart-avro/issues/22)).
- `DecodeException.blockOffset` says where in a container file the block of a failing record starts; `offset` counts inside the decompressed block ([avro-1016](https://github.com/paxel/dart-avro/issues/19)).

### Changed

- `AvroFileReader.records(codec)` rejects a codec whose writer schema is not the file's, with `DecodeException` naming both fingerprints, before it decodes a record ([avro-1015](https://github.com/paxel/dart-avro/issues/18)).
- A writer value read as a reader union takes the branch Apache Avro's Java implementation takes: the same type or full name first, then a record that resolves, then a promotion. An `int` read as `["null", "double", "int"]` now stays an `int` ([avro-1017](https://github.com/paxel/dart-avro/issues/20)).
- Every limit of `AvroLimits` throws `LimitExceededException`: a value nested deeper than `maxValueDepth` on encode, and a container block with more zero-size records than `maxZeroSizeItems`, no longer throw `EncodeException` and `DecodeException` ([avro-1014](https://github.com/paxel/dart-avro/issues/17)).

### Fixed

- A string that is not a UUID, encoded as the logical type `uuid`, fails with `"…" is not a UUID` instead of "expected a UUID String for uuid, got String" ([avro-1018](https://github.com/paxel/dart-avro/issues/21)).
- The API documentation of `AvroLimits.maxZeroSizeItems` says it bounds arrays and container blocks, not maps ([avro-1018](https://github.com/paxel/dart-avro/issues/21)).

## [0.1.1] - 2026-11-21

### Changed

- No change to the package; this version is the first one published to pub.dev by the release workflow.

## [0.1.0] - 2026-11-21

### Added

- `Schema.parse` reads any Avro 1.12 schema into an immutable tree that keeps `doc`, aliases, defaults and custom attributes.
- `AvroCodec` encodes and decodes every primitive and complex type in Avro's binary encoding, with records and maps as `Map<String, Object?>`, and rejects malformed input with an `AvroException`.
- `Schema.canonicalForm` gives the Parsing Canonical Form, and `crc64`, `md5` and `sha256` its fingerprints; CRC-64-AVRO is an `int`, with `crc64ToBytes` and `crc64FromBytes` for its 8 little-endian bytes.
- Every logical type of Avro 1.12 decodes to a Dart value: `DateTime`, `Duration` and `String` where they fit, `AvroDate`, `AvroLocalTimestamp`, `AvroTimestampNanos`, `AvroDecimal` and `AvroDuration` where Dart has none.
- `AvroCodec(writer:, reader:)` reads data of one schema as another by Avro's schema resolution, compiled once when the codec is made; schemas that do not resolve throw `ResolutionException`.
- Single-object encoding: `encodeSingleObject`, `decodeSingleObject`, and `SingleObjectHeader.parse` to read a message's fingerprint before choosing its codec.
- `AvroFileReader` reads object container files compressed with `null` or `deflate`: the header first, then the records lazily, one block at a time, with the file's schema or a codec of the caller's choice.
- `AvroFileWriter` writes object container files compressed with `null` or `deflate`, with the caller's metadata in its order, the schema text and sync marker of the caller's choice, and blocks ended by size or by `flush`.
- User documentation on GitHub Pages: a Start track, a Guide with one task per page and a Reference, with every example run as a test.
- Union values whose branch is ambiguous are written with `Branch`.
- `AvroLimits` bounds schema size, schema and value nesting, and empty-item counts, with finite defaults.
