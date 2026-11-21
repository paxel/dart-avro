# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0]

### Added

- `DecodeException.blockOffset` says where in a container file the block of a failing record starts; `offset` counts inside the decompressed block.

### Changed

- `AvroFileReader.records(codec)` rejects a codec whose writer schema is not the file's, with `DecodeException` naming both fingerprints, before it decodes a record.
- A writer value read as a reader union takes the branch Apache Avro's Java implementation takes: the same type or full name first, then a record that resolves, then a promotion. An `int` read as `["null", "double", "long"]` now stays an `int`.
- Every limit of `AvroLimits` throws `LimitExceededException`: a value nested deeper than `maxValueDepth` on encode, and a container block with more zero-size records than `maxZeroSizeItems`, no longer throw `EncodeException` and `DecodeException`.

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
