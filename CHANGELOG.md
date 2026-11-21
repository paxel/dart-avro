# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0]

### Changed

- Every limit of `AvroLimits` throws `LimitExceededException`: a value nested deeper than `maxValueDepth` on encode, and a container block with more zero-size records than `maxZeroSizeItems`, no longer throw `EncodeException` and `DecodeException`.

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
