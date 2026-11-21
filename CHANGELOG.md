# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0]

### Added

- `Schema.parse` reads any Avro 1.12 schema into an immutable tree that keeps `doc`, aliases, defaults and custom attributes.
- `AvroCodec` encodes and decodes every primitive and complex type in Avro's binary encoding, with records and maps as `Map<String, Object?>`, and rejects malformed input with an `AvroException`.
- `Schema.canonicalForm` gives the Parsing Canonical Form, and `crc64`, `md5` and `sha256` its fingerprints; CRC-64-AVRO is an `int`, with `crc64ToBytes` and `crc64FromBytes` for its 8 little-endian bytes.
- Every logical type of Avro 1.12 decodes to a Dart value: `DateTime`, `Duration` and `String` where they fit, `AvroDate`, `AvroLocalTimestamp`, `AvroTimestampNanos`, `AvroDecimal` and `AvroDuration` where Dart has none.
- `AvroCodec(writer:, reader:)` reads data of one schema as another by Avro's schema resolution, compiled once when the codec is made; schemas that do not resolve throw `ResolutionException`.
- Union values whose branch is ambiguous are written with `Branch`.
- `AvroLimits` bounds schema size, schema and value nesting, and empty-item counts, with finite defaults.

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
