# Older changes

Released versions before the current one, newest first.

## [0.3.0] - 2026-11-21

### Added

- The docs site has Guide pages on JSON encoding, the compressions and streamed container files, Reference pages for JSON and container files, and describes 0.3.0 ([avro-1034](https://github.com/paxel/dart-avro/issues/38)).
- `AvroFileReader` reads and `AvroFileWriter(compression: 'snappy')` writes container files compressed with `snappy`, in pure Dart, with the CRC32 of each block checked on reading ([avro-1026](https://github.com/paxel/dart-avro/issues/30)).
- `AvroFileReader` reads and `AvroFileWriter` writes container files compressed with `bzip2`, `xz` and `zstandard`, stopping decompression at the limits; `xz` blocks are written without being compressed ([avro-1027](https://github.com/paxel/dart-avro/issues/31)).
- `AvroCodec.encodeJson` and `decodeJson`, and the same on `TypedCodec`, write and read Avro's JSON encoding, with `indent:` for indented output and resolution on decoding; a union is `null` or `{"<branch>": value}`, and `NaN` and the infinities are strings ([avro-1028](https://github.com/paxel/dart-avro/issues/32)).
- `AvroCodec(decodeBranches: true)` decodes every union with two or more non-null branches into a `Branch` of the reader's branch, in `decode`, `decodeSingleObject`, `decodeJson`, the records of a container file and reader defaults, so a decoded value encodes back unchanged; `null` and a union of `null` and one other branch stay plain ([avro-1029](https://github.com/paxel/dart-avro/issues/33)).
- `package:avro/generate.dart` makes the generator a library: `generateDart` takes schema texts as `SchemaSource`s and the prefixes, without files, and returns the unformatted Dart source and the warnings as a `GeneratedLibrary`, or throws `GenerateException`; `dart run avro:generate` is a wrapper around it ([avro-1031](https://github.com/paxel/dart-avro/issues/35)).
- `AvroFileStreamReader.open` reads a container file from a `Stream<List<int>>`, completing once the header has arrived, and its `records()` is a `Stream` of the records with the same codec check, errors and offsets as `AvroFileReader`, holding one block in memory at a time; `maxBlockBytes` also bounds a block's compressed size and the header, so a huge declared block or metadata value fails before it is read, and `cancel()` ends the reading ([avro-1032](https://github.com/paxel/dart-avro/issues/36)).
- `AvroFileStreamWriter` writes a container file to a `StreamSink<List<int>>`: the header at once and each block as it ends, with the options and rules of `AvroFileWriter` and byte for byte its output, through `add`, `flush` and a `close()` that completes when the sink is closed ([avro-1033](https://github.com/paxel/dart-avro/issues/37)).

### Changed

- Breaking: `dart run avro:generate` maps a union with two or more non-null branches to a `sealed class` per place of use, named after the record and the field, with a `final class` per branch, instead of `Object?`, and `TypedCodec` decodes with `decodeBranches`, so code generated with 0.2.0 that holds such a union as `Object?` must be regenerated and updated; a record or enum named `Branch` now needs a `--prefix` ([avro-1030](https://github.com/paxel/dart-avro/issues/34)).

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
