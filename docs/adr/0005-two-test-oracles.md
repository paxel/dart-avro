# 5. Two test oracles: Apache test data and Python avro

Date: 2026-11-21

## Status

Accepted.

## Context

The AXT conformance vectors test `axt_protocol`, not this package. The Apache Avro repository publishes, under Apache-2.0, `share/test/data/schema-tests.txt` (schemas with their canonical forms and CRC-64-AVRO fingerprints), `share/test/data/weather.avro` and `weather-deflate.avro` with `weather.json`, and `share/test/schemas/interop.avsc`. None of it covers schema resolution, single-object encoding, or whether another implementation reads the files this package writes.

## Decision

- `dart test` runs against the Apache test data, vendored into `test/` with its licence notice, and against byte-exact cases written by hand from the Avro 1.12 specification. It needs nothing but Dart.
- A separate CI job round-trips data with the Python `avro` package, the official Apache library: Python writes and Dart reads, and Dart writes and Python reads, across what that package supports.
- What Python `avro` does not support is checked by the hand-written cases only, with no second implementation: single-object encoding, `timestamp-nanos`, `local-timestamp-millis`, `-micros` and `-nanos`, `big-decimal`, `duration` and `uuid` on `fixed`. Single-object encoding also gets the bytes of AXT's example message (`spec/envelope.md`, section 10.2), which fastavro wrote. These features are a thin layer over encodings that the interop job does check (`long`, `bytes`, `fixed`).

## Consequences

- CI needs Python for the interop job only.
- Python `avro` 1.12.2 has no single-object encoding, and of the logical types it supports only `date`, `decimal`, `time-millis`, `time-micros`, `timestamp-millis`, `timestamp-micros` and `uuid` on `string` (its `constants.py`). fastavro 1.13.1 adds only `local-timestamp-millis` and `local-timestamp-micros`. A Java job, which would cover the rest, was rejected: a second runtime in CI costs more than it would find.
- The Python `avro` package 1.12.2 computes some canonical forms wrongly (it writes `{"type":"string"}` for a primitive with a logical type; `paxel/axt`, `spec/envelope.md`, section 5). The interop job compares data, not fingerprints, and the fingerprints are pinned by `schema-tests.txt`.
