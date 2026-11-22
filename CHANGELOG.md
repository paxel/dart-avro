# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0]

### Added

- `AvroFileReader` and `AvroFileWriter`, and their stream versions, read and write `deflate` container files on platforms without `dart:io`, such as a dart2wasm build, through `archive`'s pure-Dart DEFLATE, stopping at the same limits; the VM and AOT keep `dart:io`'s zlib ([avro-1038](https://github.com/paxel/dart-avro/issues/43)).

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
