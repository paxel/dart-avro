[![CI](https://github.com/paxel/dart-avro/actions/workflows/ci.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/ci.yml)
[![Security](https://github.com/paxel/dart-avro/actions/workflows/security.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/security.yml)
[![CodeQL](https://github.com/paxel/dart-avro/actions/workflows/codeql.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/paxel/dart-avro/badge)](https://scorecard.dev/viewer/?uri=github.com/paxel/dart-avro)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=paxel_dart-avro&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=paxel_dart-avro)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpaxel%2Fdart-avro%2Fsummer%2F.github%2Fbadges%2Fcoverage-dart.json)](coverage-floors.toml)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpaxel%2Fdart-avro%2Fsummer%2F.github%2Fbadges%2Fcoverage-site.json)](coverage-floors.toml)
[![Fuzz](https://github.com/paxel/dart-avro/actions/workflows/fuzz.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/fuzz.yml)
[![Release](https://img.shields.io/github/v/release/paxel/dart-avro)](https://github.com/paxel/dart-avro/releases)
[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue)](LICENSE-MIT)
[![pub.dev](https://img.shields.io/pub/v/avro)](https://pub.dev/packages/avro) [![docs](https://img.shields.io/badge/docs-paxel.github.io%2Fdart--avro-blue)](https://paxel.github.io/dart-avro/)

# avro

A pure-Dart implementation of [Apache Avro 1.12](https://avro.apache.org/docs/1.12.0/specification/) for the Dart VM and AOT: Android, iOS and desktop; and for the web when compiled with dart2wasm (`flutter build web --wasm`). Compiled with dart2js, where an `int` is not 64-bit, its codecs throw `UnsupportedError`.

## Documentation

- The user guide: https://paxel.github.io/dart-avro/, with a Start track, a Guide with one task per page, and a Reference.
- The API reference: https://pub.dev/documentation/avro/latest/.

## What it covers

- Every primitive, complex and logical type of Avro 1.12.
- Binary encoding, single-object encoding and JSON encoding.
- Schema parsing and schema resolution between a writer and a reader schema.
- A schema compatibility check without data, `checkCompatibility`, with every incompatibility and its place in both schemas.
- The Avro sort order: `compare` of two values and `compareBytes` of two encodings without decoding them.
- Parsing Canonical Form, with the fingerprints CRC-64-AVRO, MD5 and SHA-256.
- Object container files, read and write, in memory or as streams, compressed with `null`, `deflate`, `snappy`, `bzip2`, `xz` or `zstandard`.
- Typed Dart classes generated from `.avsc` files with `dart run avro:generate` or the library `package:avro/generate.dart`, with a sealed class for each union of two or more non-null branches, encoded and decoded with `TypedCodec`.

Not covered: the Avro IPC/RPC protocol, and the web compiled with dart2js.

## Licence

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT License](LICENSE-MIT), at your option.
