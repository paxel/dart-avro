# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0]

### Added

- `AvroFileReader` reads and `AvroFileWriter(compression: 'snappy')` writes container files compressed with `snappy`, in pure Dart, with the CRC32 of each block checked on reading ([avro-1026](https://github.com/paxel/dart-avro/issues/30)).
- `AvroFileReader` reads and `AvroFileWriter` writes container files compressed with `bzip2`, `xz` and `zstandard`, stopping decompression at the limits; `xz` blocks are written without being compressed ([avro-1027](https://github.com/paxel/dart-avro/issues/31)).
- `AvroCodec.encodeJson` and `decodeJson`, and the same on `TypedCodec`, write and read Avro's JSON encoding, with `indent:` for indented output and resolution on decoding; a union is `null` or `{"<branch>": value}`, and `NaN` and the infinities are strings ([avro-1028](https://github.com/paxel/dart-avro/issues/32)).
- `AvroCodec(decodeBranches: true)` decodes every union with two or more non-null branches into a `Branch` of the reader's branch, in `decode`, `decodeSingleObject`, `decodeJson`, the records of a container file and reader defaults, so a decoded value encodes back unchanged; `null` and a union of `null` and one other branch stay plain ([avro-1029](https://github.com/paxel/dart-avro/issues/33)).

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
