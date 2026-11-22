# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0]

### Added

- The package runs on the web when compiled with dart2wasm, and `pubspec.yaml` lists `web`. Under dart2js, where an `int` cannot hold Avro's 64-bit values, creating an `AvroCodec`, a `TypedCodec`, an `AvroFileReader` or `AvroFileWriter`, or their stream versions, and calling `crc64Avro`, `crc64ToBytes`, `crc64FromBytes` or `Schema.crc64`, throws `UnsupportedError("avro needs 64-bit integers: compile for the web with dart2wasm")` instead of giving wrong results ([avro-1039](https://github.com/paxel/dart-avro/issues/44)).
- `AvroFileReader` and `AvroFileWriter`, and their stream versions, read and write `deflate` container files on platforms without `dart:io`, such as a dart2wasm build, through `archive`'s pure-Dart DEFLATE, stopping at the same limits; the VM and AOT keep `dart:io`'s zlib ([avro-1038](https://github.com/paxel/dart-avro/issues/43)).
- `AvroCodec.compare` compares two values, and `AvroCodec.compareBytes` two encodings without decoding them, by the Avro sort order: records field by field in each field's `order` (`ascending`, `descending` or `ignore`), unions by branch index and then value, enums by symbol index, strings and bytes as unsigned bytes, numbers by value (`NaN` last, as in Java), and logical values as their underlying values; maps throw `ArgumentError`. `TypedCodec.compare` does the same for typed values ([avro-1041](https://github.com/paxel/dart-avro/issues/46)).
- `checkCompatibility(reader:, writer:)` reports, without data, every reason data of the writer schema cannot be read as the reader schema, each an `Incompatibility` with its kind (named after Java's `SchemaIncompatibilityType`, plus `decimalMismatch`), its path in the reader and in the writer schema, and a message. It agrees with the schema resolution of `AvroCodec`, and also reports what fails only for some data: a writer enum symbol the reader lacks without a default, and a writer union branch that does not resolve ([avro-1042](https://github.com/paxel/dart-avro/issues/47)).

### Changed

- `AvroCodec` encodes binary data, and decodes it when the reader schema is the writer schema, 5 to 10 times as fast as before on the records of the benchmark suite (`docs/benchmarks.md`), within 2× of Apache Avro for Java: it compiles the writer schema into code once, at the first `encode` or `decode`, instead of walking the schema for every value. Errors, their messages and paths, and limits are unchanged ([avro-1037](https://github.com/paxel/dart-avro/issues/42)).

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
