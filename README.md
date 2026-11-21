[![CI](https://github.com/paxel/dart-avro/actions/workflows/ci.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/ci.yml)
[![Security](https://github.com/paxel/dart-avro/actions/workflows/security.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/security.yml)
[![CodeQL](https://github.com/paxel/dart-avro/actions/workflows/codeql.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/paxel/dart-avro/badge)](https://scorecard.dev/viewer/?uri=github.com/paxel/dart-avro)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=paxel_dart-avro&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=paxel_dart-avro)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fpaxel%2Fdart-avro%2Fsummer%2F.github%2Fbadges%2Fcoverage-dart.json)](coverage-floors.toml)
[![Fuzz](https://github.com/paxel/dart-avro/actions/workflows/fuzz.yml/badge.svg?branch=summer)](https://github.com/paxel/dart-avro/actions/workflows/fuzz.yml)
[![Release](https://img.shields.io/github/v/release/paxel/dart-avro)](https://github.com/paxel/dart-avro/releases)
[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue)](LICENSE-MIT)
[![pub](https://img.shields.io/pub/v/avro)](https://pub.dev/packages/avro)

# avro

A pure-Dart implementation of [Apache Avro 1.12](https://avro.apache.org/docs/1.12.0/specification/) for the Dart VM and AOT: Android, iOS and desktop. Flutter web is not supported.

## Scope of the first release

- Every primitive, complex and logical type of Avro 1.12.
- Binary encoding and single-object encoding.
- Schema parsing and schema resolution between a writer and a reader schema.
- Parsing Canonical Form, with the fingerprints CRC-64-AVRO, MD5 and SHA-256.
- Object container files, read and write, compressed with `null` or `deflate`.

Not in the first release: JSON encoding, the compressions `snappy`, `bzip2`, `xz` and `zstandard`, the Avro IPC/RPC protocol and code generation.

## Licence

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT License](LICENSE-MIT), at your option.
