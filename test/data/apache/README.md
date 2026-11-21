# Apache Avro test data

The files in this directory are copied unchanged from the Apache Avro repository,
https://github.com/apache/avro, tag `release-1.12.2`. They are licensed under the Apache
License, Version 2.0 ([LICENSE-APACHE](../../../LICENSE-APACHE)); `NOTICE.txt` is the
repository's notice.

| File                  | Source path                           |
|-----------------------|---------------------------------------|
| `interop.avsc`        | `share/test/schemas/interop.avsc`     |
| `schema-tests.txt`    | `share/test/data/schema-tests.txt`    |
| `weather.avro`        | `share/test/data/weather.avro`        |
| `weather-snappy.avro` | `share/test/data/weather-snappy.avro` |
| `weather.json`        | `share/test/data/weather.json`        |
| `syncInMeta.avro`     | `share/test/data/syncInMeta.avro`     |

`weather-deflate.avro` and `weather-zstd.avro` are not in that tag; they are copied from
`share/test/data/` at commit `54b332161524086dcb6cde8afe097097eed7f3ee` (AVRO-4172).
