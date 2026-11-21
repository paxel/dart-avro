# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0]

### Added

- `AvroFileReader` reads and `AvroFileWriter(compression: 'snappy')` writes container files compressed with `snappy`, in pure Dart, with the CRC32 of each block checked on reading ([avro-1026](https://github.com/paxel/dart-avro/issues/30)).

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
