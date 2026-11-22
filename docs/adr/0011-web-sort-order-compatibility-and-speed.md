# 11. Web through dart2wasm, sort order, a compatibility check, and a speed target

Date: 2026-11-22

## Status

Accepted. Extends ADR 1 (platforms) and ADR 2 (the codec).

## Context

0.3 runs on the Dart VM and AOT only:

- **DEFLATE:** it comes from `dart:io`.
- **Integers:** with dart2js a Dart `int` is a JavaScript number, exact only to 2^53 and with 32-bit bit operations, so `long` varints, zig-zag and CRC-64 would silently go wrong. With dart2wasm, Flutter's WebAssembly build, `int` is 64-bit.
- **Missing pieces:** the package parses a field's `order` but compares nothing, and it reports schema compatibility only by throwing from a resolving codec.
- **Speed:** there is no benchmark, and the codec walks the schema tree for every value.
- **RPC:** Java's Avro RPC (avro-ipc 1.12.1) exists, but there is no service to call.

## Decision

- **Web through dart2wasm.**
  - `deflate` uses `dart:io`'s zlib on the VM and AOT, and `archive`'s pure-Dart inflate and deflate on the web, through a conditional import.
  - Under dart2js (`identical(0, 0.0)`), creating a codec, a typed codec or a container reader or writer throws `UnsupportedError` asking for dart2wasm.
  - `pubspec.yaml` lists `web`, and the docs say web means dart2wasm.
  - A CI job runs the tests tagged `web`, which need no `dart:io`, with `dart test -p chrome --compiler dart2wasm`.
- **Sort order.**
  - `AvroCodec.compare(a, b)` compares two generic values, and `compareBytes(a, b)` two encodings without decoding them, by the spec's sort order: field by field with `ascending`, `descending` and `ignore`, and unions by branch index, then value.
  - Enums compare by symbol index, strings and bytes as unsigned bytes. Maps cannot be compared and throw.
  - `TypedCodec.compare` does the same for typed values.
- **Compatibility check.** `checkCompatibility(reader:, writer:)` returns every incompatibility, with its place in the schemas and its kind, without data, as Java's `SchemaCompatibility` does. A resolving codec still throws as before.
- **Speed.**
  - A benchmark suite covers encode, decode, resolution, JSON, container files per compression and generated classes.
  - A one-off comparison with Java Avro 1.12 (warmed-up generic reader and writer) and fastavro runs on the same data, and its results are published.
  - The codec compiles its work into a plan per schema until binary encode and decode of records are within 2× of Java, on the Dart AOT build. JSON, compressions and container files are measured without a target.

## Considered options

- dart2js with emulated 64-bit arithmetic: an API change (`Int64` or `BigInt` for `long`) and slower code, for a build Flutter is moving away from.
- `archive`'s DEFLATE on every platform: one implementation, but slower native apps.
- The RPC protocol with its HTTP transport: possible, but without a user yet.
- A CI regression guard for the benchmarks: CI runners are too noisy before a baseline exists.

## Consequences

- Flutter web apps built for WebAssembly can use the package; apps built with dart2js get an error at first use.
- The comparison with Java is a documented, repeatable script, not a CI gate.
