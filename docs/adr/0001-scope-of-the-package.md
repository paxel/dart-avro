# 1. A pure-Dart Avro package, native only, binary core first

Date: 2026-11-21

## Status

Accepted.

## Context

No usable Avro library exists for Dart. The only one on pub.dev, `dart_avro` 0.0.3, is archived since 2024-08, decodes only and is licensed AGPL-3.0; `sqs/avro-dart` is a schema parser untouched since 2012. The first consumer is `axt_protocol` in `paxel/axt-dart`, which needs the binary encoding, single-object encoding, container files, Parsing Canonical Form, fingerprints and schema resolution of Avro 1.12 (`paxel/axt`, `spec/envelope.md`). Its first apps, cat-a-log and Old Brain Fix, run on Android, iOS and desktop, with no web target.

## Decision

- A package of its own, `avro` on pub.dev, in this repository, with its own gates, tags and SemVer, dual licensed MIT/Apache-2.0.
- Native only: the Dart VM and AOT. A Dart `int` is 64 bits there, so `long` maps to `int` directly, and raw DEFLATE comes from `dart:io` (`ZLibCodec(raw: true)`).
- The Dart SDK constraint must not exceed `^3.13.4`, the version Old Brain Fix pins.
- The first release covers the binary core of Avro 1.12: every primitive, complex and logical type; binary and single-object encoding; schema parsing and resolution; Parsing Canonical Form with CRC-64-AVRO, MD5 and SHA-256 fingerprints; object container files, read and write, compressed with `null` or `deflate`. A reader rejects any other compression.
- Not in the first release: JSON encoding, the compressions `snappy`, `bzip2`, `xz` and `zstandard`, the IPC/RPC protocol and code generation. They may follow as minor versions.
- No code of `dart_avro` is read or copied, so that the package stays free of AGPL.

## Consequences

- The package does not run on Flutter web. Supporting it later would mean replacing `dart:io` for DEFLATE and handling 64-bit `long` values.
- Applications that need another compression cannot read such files with this package until that compression is added.
