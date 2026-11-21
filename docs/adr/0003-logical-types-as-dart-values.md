# 3. Logical types as Dart values, with own classes where Dart has none

Date: 2026-11-21

## Status

Accepted.

## Context

Dart has no decimal type, its `DateTime` stops at microseconds, and a `DateTime` is always either UTC or the device's local zone. Avro 1.12 has logical types for decimals, nanosecond timestamps and date-times without a zone.

## Decision

`decode` returns, and `encode` accepts:

| Logical type                                                        | Dart value                                                   |
|---------------------------------------------------------------------|--------------------------------------------------------------|
| `uuid` (on `string` or `fixed` 16)                                  | `String`, 36 characters, lower case                          |
| `time-millis`, `time-micros`                                        | `Duration` since midnight                                    |
| `timestamp-millis`, `timestamp-micros`                              | `DateTime` in UTC                                            |
| `timestamp-nanos`                                                   | `AvroTimestampNanos`: epoch nanoseconds, with `toDateTime()` |
| `date`                                                              | `AvroDate`: year, month, day                                 |
| `local-timestamp-millis`, `-micros`, `-nanos`                       | `AvroLocalTimestamp`: wall-clock fields, with `toDateTime()` |
| `decimal`, `big-decimal`                                            | `AvroDecimal`: unscaled `BigInt` and scale                   |
| `duration`                                                          | `AvroDuration`: months, days, milliseconds                   |

A logical type the package does not know is read as its underlying type, as the Avro specification says.

## Considered options

- `DateTime.utc` carrying the wall-clock fields of `date` and the local timestamps: code that converts it to local time gets a wrong value without noticing.
- Returning the underlying values (`int`, `Uint8List`) with conversion helpers: nothing is lost, but every caller converts by hand.

## Consequences

- A Dart `DateTime` covers 100,000,000 days either side of the epoch. A `timestamp-millis` or `timestamp-micros` value outside that range, which a `long` can hold, has no `DateTime`. `decode` throws `DecodeException` for it, naming the field and the value, so that a field keeps one Dart type whatever its value.
