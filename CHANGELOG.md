# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0]

### Added

- The package runs on the web when compiled with dart2wasm, and `pubspec.yaml` lists `web`. Under dart2js, where an `int` cannot hold Avro's 64-bit values, creating an `AvroCodec`, a `TypedCodec`, an `AvroFileReader` or `AvroFileWriter`, or their stream versions, and calling `crc64Avro`, `crc64ToBytes`, `crc64FromBytes` or `Schema.crc64`, throws `UnsupportedError("avro needs 64-bit integers: compile for the web with dart2wasm")` instead of giving wrong results ([avro-1039](https://github.com/paxel/dart-avro/issues/44)).
- `AvroFileReader` and `AvroFileWriter`, and their stream versions, read and write `deflate` container files on platforms without `dart:io`, such as a dart2wasm build, through `archive`'s pure-Dart DEFLATE, stopping at the same limits; the VM and AOT keep `dart:io`'s zlib ([avro-1038](https://github.com/paxel/dart-avro/issues/43)).
- `AvroCodec.compare` compares two values, and `AvroCodec.compareBytes` two encodings without decoding them, by the Avro sort order: records field by field in each field's `order` (`ascending`, `descending` or `ignore`), unions by branch index and then value, enums by symbol index, strings and bytes as unsigned bytes, numbers by value (`NaN` last, as in Java), and logical values as their underlying values; maps throw `ArgumentError`. `TypedCodec.compare` does the same for typed values ([avro-1041](https://github.com/paxel/dart-avro/issues/46)).

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
