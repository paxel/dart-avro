import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

AvroCodec codecOf(String json) => AvroCodec(writer: Schema.parse(json));

Uint8List b(List<int> bytes) => Uint8List.fromList(bytes);

String logical(String type, String logicalType, [String extra = '']) =>
    '{"type": "$type", "logicalType": "$logicalType"$extra}';

void roundTrip(String schema, Object? value, List<int> bytes) {
  final codec = codecOf(schema);
  expect(codec.encode(value), bytes, reason: 'encode $value');
  expect(codec.decode(b(bytes)), value, reason: 'decode $bytes');
}

/// The zig-zag varint of [v], as the plain `long` encoding writes it.
List<int> long(int v) => codecOf('"long"').encode(v);

void main() {
  group('uuid', () {
    const text = '123e4567-e89b-12d3-a456-426614174000';
    test('on string, as lower-case text', () {
      final s = logical('string', 'uuid');
      roundTrip(s, text, codecOf('"string"').encode(text));
      expect(codecOf(s).encode(text.toUpperCase()), codecOf(s).encode(text));
      expect(
        codecOf(s).decode(codecOf('"string"').encode(text.toUpperCase())),
        text,
      );
    });

    test('on fixed 16, as its 16 bytes', () {
      const s =
          '{"type": "fixed", "name": "U", "size": 16, "logicalType": "uuid"}';
      roundTrip(s, text, [
        0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3, //
        0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00,
      ]);
    });

    test('a string that is not a UUID is rejected', () {
      final s = logical('string', 'uuid');
      expect(
        () => codecOf(s).encode('nope'),
        throwsA(
          isA<EncodeException>().having(
            (e) => e.message,
            'message',
            '"nope" is not a UUID',
          ),
        ),
      );
      expect(
        () => codecOf(s).decode(codecOf('"string"').encode('nope')),
        throwsA(isA<DecodeException>()),
      );
    });
  });

  group('times', () {
    test('time-millis and time-micros as Duration since midnight', () {
      roundTrip(
        logical('int', 'time-millis'),
        const Duration(hours: 1, milliseconds: 5),
        long(3600005),
      );
      roundTrip(
        logical('long', 'time-micros'),
        const Duration(microseconds: 7),
        long(7),
      );
      expect(
        () =>
            codecOf(logical('int', 'time-millis'))
                .encode(const Duration(microseconds: 1)),
        throwsA(isA<EncodeException>()),
      );
    });

    test('timestamp-millis and -micros as UTC DateTime', () {
      final t = DateTime.utc(2000, 1, 1, 10);
      roundTrip(logical('long', 'timestamp-millis'), t, long(946720800000));
      roundTrip(logical('long', 'timestamp-micros'), t, long(946720800000000));
      final decoded = codecOf(logical('long', 'timestamp-millis'))
          .decode(b(long(0)));
      expect((decoded! as DateTime).isUtc, isTrue);
      expect(
        () =>
            codecOf(logical('long', 'timestamp-millis'))
                .encode(DateTime.utc(2000, 1, 1, 0, 0, 0, 0, 1)),
        throwsA(isA<EncodeException>()),
      );
    });

    test('a timestamp beyond the range of DateTime is rejected', () {
      expect(
        () =>
            codecOf(logical('long', 'timestamp-millis'))
                .decode(b(long(8640000000000001))),
        throwsA(
          isA<DecodeException>().having(
            (e) => e.message,
            'message',
            contains('8640000000000001'),
          ),
        ),
      );
      expect(
        () =>
            codecOf(logical('long', 'timestamp-micros'))
                .decode(b(long(-0x7fffffffffffffff))),
        throwsA(isA<DecodeException>()),
      );
    });

    test('timestamp-nanos as AvroTimestampNanos', () {
      roundTrip(
        logical('long', 'timestamp-nanos'),
        const AvroTimestampNanos(946720800000000001),
        long(946720800000000001),
      );
      expect(
        const AvroTimestampNanos(946720800000000001).toDateTime(),
        DateTime.utc(2000, 1, 1, 10),
      );
      expect(
        const AvroTimestampNanos(-1).toDateTime(),
        DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 999),
      );
    });

    test('local timestamps as AvroLocalTimestamp, without a zone', () {
      // The Helsinki example of the specification: noon local time on 1 January 2000.
      const noon = AvroLocalTimestamp(2000, 1, 1, 12);
      roundTrip(
        logical('long', 'local-timestamp-millis'),
        noon,
        long(946728000000),
      );
      roundTrip(
        logical('long', 'local-timestamp-micros'),
        noon,
        long(946728000000000),
      );
      roundTrip(
        logical('long', 'local-timestamp-nanos'),
        noon,
        long(946728000000000000),
      );
      const before = AvroLocalTimestamp(1969, 12, 31, 23, 59, 59, 999000000);
      roundTrip(logical('long', 'local-timestamp-millis'), before, long(-1));
      expect(noon.toDateTime(), DateTime(2000, 1, 1, 12));
      expect(
        () =>
            codecOf(logical('long', 'local-timestamp-millis'))
                .encode(const AvroLocalTimestamp(2000, 1, 1, 0, 0, 0, 1)),
        throwsA(isA<EncodeException>()),
      );
    });

    test('date as AvroDate, over the whole int range', () {
      roundTrip(logical('int', 'date'), const AvroDate(1970, 1, 1), long(0));
      roundTrip(
        logical('int', 'date'),
        const AvroDate(2000, 3, 1),
        long(11017),
      );
      roundTrip(logical('int', 'date'), const AvroDate(1969, 12, 31), long(-1));
      for (final days in [-0x80000000, 0x7fffffff, -719468, 1000000]) {
        expect(AvroDate.fromEpochDays(days).epochDays, days);
      }
      expect(const AvroDate(2024, 2, 29).toString(), '2024-02-29');
    });
  });

  group('decimal', () {
    test('on bytes, as two\'s complement', () {
      final s = logical('bytes', 'decimal', ', "precision": 4, "scale": 2');
      roundTrip(s, AvroDecimal(BigInt.from(1234), 2), [4, 0x04, 0xd2]);
      roundTrip(s, AvroDecimal(BigInt.from(-1), 2), [2, 0xff]);
      roundTrip(s, AvroDecimal(BigInt.zero, 2), [2, 0x00]);
      roundTrip(s, AvroDecimal(BigInt.from(128), 2), [4, 0x00, 0x80]);
      expect(AvroDecimal(BigInt.from(-1234), 2).toString(), '-12.34');
      expect(AvroDecimal(BigInt.from(5), 3).toString(), '0.005');
    });

    test('on fixed, sign-extended to its size', () {
      const s =
          '{"type": "fixed", "name": "D", "size": 3, "logicalType": "decimal", "precision": 5}';
      roundTrip(s, AvroDecimal(BigInt.from(-2), 0), [0xff, 0xff, 0xfe]);
      roundTrip(s, AvroDecimal(BigInt.from(99999), 0), [0x01, 0x86, 0x9f]);
    });

    test('a value of another scale or too many digits is rejected', () {
      final s = logical('bytes', 'decimal', ', "precision": 4, "scale": 2');
      expect(
        () => codecOf(s).encode(AvroDecimal(BigInt.one, 1)),
        throwsA(isA<EncodeException>()),
      );
      expect(
        () => codecOf(s).encode(AvroDecimal(BigInt.from(12345), 2)),
        throwsA(isA<EncodeException>()),
      );
    });

    test('an invalid decimal is read as its underlying type', () {
      final s = logical('bytes', 'decimal', ', "precision": 2, "scale": 3');
      expect(codecOf(s).decode(b([2, 7])), b([7]));
      const fixed =
          '{"type": "fixed", "name": "F", "size": 1, "logicalType": "decimal", "precision": 3}';
      expect(codecOf(fixed).decode(b([7])), b([7]));
    });

    test('big-decimal carries its scale', () {
      final s = logical('bytes', 'big-decimal');
      // The bytes hold the unscaled value as bytes, then the scale as an int.
      roundTrip(s, AvroDecimal(BigInt.from(1234), 2), [8, 4, 0x04, 0xd2, 4]);
      expect(
        () => codecOf(s).decode(b([2, 9])),
        throwsA(isA<DecodeException>()),
      );
    });
  });

  test('duration as AvroDuration, three unsigned little-endian ints', () {
    const s =
        '{"type": "fixed", "name": "D", "size": 12, "logicalType": "duration"}';
    roundTrip(s, const AvroDuration(1, 2, 0xffffffff), [
      1, 0, 0, 0, 2, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, //
    ]);
    expect(
      () => codecOf(s).encode(const AvroDuration(-1, 0, 0)),
      throwsA(isA<EncodeException>()),
    );
  });

  group('the underlying type is used', () {
    test('for an unknown logical type', () {
      roundTrip(
        logical('string', 'colour'),
        'red',
        codecOf('"string"').encode('red'),
      );
    });

    test('for a logical type on the wrong underlying type', () {
      roundTrip(
        logical('string', 'date'),
        'x',
        codecOf('"string"').encode('x'),
      );
      roundTrip(logical('int', 'timestamp-millis'), 3, long(3));
      const notDuration =
          '{"type": "fixed", "name": "D", "size": 4, "logicalType": "duration"}';
      expect(codecOf(notDuration).decode(b([1, 2, 3, 4])), b([1, 2, 3, 4]));
    });
  });

  test('a union infers a logical branch from the Dart value', () {
    final codec = codecOf(
      '["null", ${logical('long', 'timestamp-millis')}, "string"]',
    );
    expect(codec.encode(DateTime.utc(1970)), [2, 0]);
    expect(codec.decode(b([2, 0])), DateTime.utc(1970));
  });

  test('a default of a logical type becomes its Dart value', () {
    final s = Schema.parse('''
{"type": "record", "name": "R", "fields": [
  {"name": "d", "type": ${logical('int', 'date')}, "default": 1},
  {"name": "u", "type": ${logical('string', 'uuid')}, "default": "123E4567-E89B-12D3-A456-426614174000"}
]}''') as RecordSchema;
    expect(s.fields[0].defaultValue, const AvroDate(1970, 1, 2));
    expect(s.fields[1].defaultValue, '123e4567-e89b-12d3-a456-426614174000');
  });

  test('the wrong Dart value for a logical type is rejected', () {
    expect(
      () => codecOf(logical('int', 'date')).encode(3),
      throwsA(isA<EncodeException>()),
    );
  });
}
