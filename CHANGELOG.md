# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0]

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

---

Historical changes have been moved to [OLDER_CHANGES.md](OLDER_CHANGES.md).
