// The compiled encoder and decoder of avro-1037: they give up on anything wrong, and the tree
// walk runs again for the error, so errors after valid values must come out as they always
// have; decoded records are maps backed by a list.
@Tags(['web'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

AvroCodec codecOf(String json) => AvroCodec(writer: Schema.parse(json));

Matcher encodeError(String message, String path) => throwsA(
  isA<EncodeException>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.path, 'path', path),
);

Matcher decodeError(String message, int offset) => throwsA(
  isA<DecodeException>()
      .having((e) => e.message, 'message', message)
      .having((e) => e.offset, 'offset', offset),
);

const everything = '''
{"type": "record", "name": "All", "fields": [
  {"name": "n", "type": "null"},
  {"name": "b", "type": "boolean"},
  {"name": "i", "type": "int"},
  {"name": "l", "type": "long"},
  {"name": "f", "type": "float"},
  {"name": "d", "type": "double"},
  {"name": "y", "type": "bytes"},
  {"name": "s", "type": "string"},
  {"name": "x", "type": {"type": "fixed", "name": "X", "size": 2}},
  {"name": "e", "type": {"type": "enum", "name": "E", "symbols": ["A", "B"]}},
  {"name": "a", "type": {"type": "array", "items": "long"}},
  {"name": "m", "type": {"type": "map", "values": "long"}},
  {"name": "u", "type": ["null", "E", "long"]},
  {"name": "o", "type": ["null", {"type": "record", "name": "In",
    "fields": [{"name": "v", "type": "long"}]}]},
  {"name": "t", "type": {"type": "long", "logicalType": "timestamp-millis"}},
  {"name": "last", "type": "long"}
]}''';

Map<String, Object?> valid() => {
  'n': null,
  'b': true,
  'i': -3,
  'l': 1 << 40,
  'f': 1.5,
  'd': -2.25,
  'y': Uint8List.fromList([1, 2]),
  's': 'aé€😀b',
  'x': Uint8List.fromList([3, 4]),
  'e': 'B',
  'a': [1, 2],
  'm': {'k': 5},
  'u': 'A',
  'o': {'v': 7},
  't': DateTime.utc(2025),
  'last': 9,
};

void main() {
  final codec = codecOf(everything);

  test('a value of every kind round-trips', () {
    final bytes = codec.encode(valid());
    final decoded = codec.decode(bytes)! as Map<String, Object?>;
    expect(decoded['s'], 'aé€😀b');
    expect(decoded['t'], DateTime.utc(2025));
    expect(codec.encode(decoded), bytes);
  });

  test('strings encode as UTF-8, ASCII or not', () {
    final strings = codecOf('"string"');
    for (final s in ['', 'abc', 'é', 'aé', '€x', '😀', 'a😀b', 'aé€😀b']) {
      final utf = utf8.encode(s);
      expect(strings.encode(s), [utf.length * 2, ...utf], reason: s);
      expect(strings.decode(strings.encode(s)), s);
    }
    expect(
      () => strings.encode('a\ud800'),
      encodeError('unpaired surrogate at index 1', r'$'),
    );
    expect(
      () => strings.encode('a\udc00b'),
      encodeError('unpaired surrogate at index 1', r'$'),
    );
    expect(
      () => strings.encode('é\ud800x'),
      encodeError('unpaired surrogate at index 1', r'$'),
    );
  });

  test('UUIDs encode and decode in lower case, and are checked', () {
    final uuids = codecOf('{"type": "string", "logicalType": "uuid"}');
    final strings = codecOf('"string"');
    const upper = '0B5A3C1E-4D2F-4A6B-9C8D-7E6F5A4B3C2D';
    final lower = upper.toLowerCase();
    expect(uuids.encode(upper), strings.encode(lower));
    expect(uuids.decode(strings.encode(upper)), lower);
    expect(uuids.decode(strings.encode(lower)), lower);
    for (final bad in [
      '0b5a3c1e-4d2f-4a6b-9c8d-7e6f5a4b3c2',
      '0b5a3c1e-4d2f-4a6b-9c8d-7e6f5a4b3c2g',
      '0b5a3c1e04d2f-4a6b-9c8d-7e6f5a4b3c2d',
      '0b5a3c1e-4d2f-4a6b-9c8d-7e6f5a4b3c-d',
      '0b5a3c1e-4d2f-4a6b-9c8d-7e6f5a4b3c2Ť',
    ]) {
      expect(
        () => uuids.encode(bad),
        encodeError('"$bad" is not a UUID', r'$'),
      );
      expect(
        () => uuids.decode(strings.encode(bad)),
        throwsA(isA<DecodeException>()),
      );
    }
  });

  group('an error after valid values comes out of the tree walk', () {
    final cases = <String, (Object?, String, String)>{
      'n': ('x', 'expected null for null, got String', r'$.n'),
      'b': (1, 'expected bool for boolean, got int', r'$.b'),
      'i': (1 << 31, '2147483648 does not fit 32 bits', r'$.i'),
      'l': (1.0, 'expected int for long, got double', r'$.l'),
      'f': ('x', 'expected double for float, got String', r'$.f'),
      'd': (null, 'expected double for double, got Null', r'$.d'),
      'y': ([1], 'expected Uint8List for bytes, got List<int>', r'$.y'),
      's': ('a\ud800', 'unpaired surrogate at index 1', r'$.s'),
      'x': (Uint8List(3), 'a fixed of 2 bytes, got 3', r'$.x'),
      'e': ('C', '"C" is not a symbol of E', r'$.e'),
      'a': ([1, 'x'], 'expected int for long, got String', r'$.a[1]'),
      'm': ({'k': 1, 'j': 'x'}, 'expected int for long, got String', r'$.m.j'),
      'u': (
        1.5,
        'no branch of the union fits double; it has null, E, long',
        r'$.u',
      ),
      'o': ({'v': 'x'}, 'expected int for long, got String', r'$.o.v'),
      't': (3, 'expected DateTime for timestamp-millis, got int', r'$.t'),
      'last': ('x', 'expected int for long, got String', r'$.last'),
    };
    for (final MapEntry(key: field, value: (value, message, path))
        in cases.entries) {
      test(field, () {
        expect(
          () => codec.encode(valid()..[field] = value),
          encodeError(message, path),
        );
      });
    }

    test('a record without a field, or with another', () {
      expect(
        () => codec.encode(valid()..remove('last')),
        encodeError('the field "last" is missing', r'$'),
      );
      expect(
        () => codec.encode(valid()..['z'] = 1),
        encodeError('"z" is not a field of All', r'$'),
      );
      expect(
        () => codec.encode(
          valid()
            ..remove('n')
            ..['n'] = null,
        ),
        returnsNormally,
      );
    });

    test('a decoded record that lost a field', () {
      final decoded =
          codec.decode(codec.encode(valid()))! as Map<String, Object?>;
      expect(
        () => codec.encode(decoded..remove('last')),
        encodeError('the field "last" is missing', r'$'),
      );
    });

    test('a value nested deeper than the limit', () {
      final shallow = AvroCodec(
        writer: Schema.parse(everything),
        limits: const AvroLimits(maxValueDepth: 1),
      );
      expect(
        () => shallow.encode(valid()),
        throwsA(
          isA<LimitExceededException>().having(
            (e) => e.message,
            'message',
            r'the value at $.a[0] is nested deeper than 1',
          ),
        ),
      );
    });
  });

  test('a datum cut short fails where the tree walk fails', () {
    final bytes = codec.encode(valid());
    expect(
      () => codec.decode(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
      decodeError('needs 1 bytes, but only 0 are left', bytes.length - 1),
    );
    final last = bytes.length - 1;
    final bad = Uint8List.fromList(bytes)..[last] = 0x80;
    expect(
      () => codec.decode(bad),
      decodeError('needs 1 bytes, but only 0 are left', bytes.length),
    );
  });

  test('a union branch is decoded as a Branch where asked', () {
    final branches = AvroCodec(
      writer: Schema.parse(everything),
      decodeBranches: true,
    );
    final decoded =
        branches.decode(codec.encode(valid()))! as Map<String, Object?>;
    expect(decoded['u'], const Branch('E', 'A'));
    expect(decoded['o'], {'v': 7});
    expect(branches.encode(decoded), codec.encode(valid()));
  });

  test('a decoded record is a map like any other', () {
    Map<String, Object?> decoded() =>
        codec.decode(codec.encode(valid()))! as Map<String, Object?>;
    final ops = <String, void Function(Map<String, Object?>)>{
      'nothing': (m) {},
      'set': (m) => m['l'] = 5,
      'add': (m) => m['z'] = 3,
      'remove': (m) => m.remove('b'),
      'remove and add': (m) => m
        ..remove('b')
        ..['b'] = false,
      'clear': (m) => m.clear(),
      'putIfAbsent': (m) => m.putIfAbsent('z', () => 1),
      'update': (m) => m.update('e', (v) => 'A'),
      'removeWhere': (m) => m.removeWhere((k, v) => k == 'i'),
    };
    String show(Map<String, Object?> m) =>
        '$m ${m.keys.toList()} ${m.values.toList()} '
        '${[for (final e in m.entries) e.key]} ${m.length} ${m.isEmpty} '
        '${m.isNotEmpty} ${m['l']} ${m['nope']} ${m.containsKey('b')}';
    for (final MapEntry(key: name, value: op) in ops.entries) {
      final ours = decoded();
      final plain = Map<String, Object?>.of(decoded());
      op(ours);
      op(plain);
      expect(show(ours), show(plain), reason: name);
    }
    final forEach = <String>[];
    decoded().forEach((k, v) => forEach.add(k));
    expect(forEach, valid().keys);
    final m = decoded();
    expect(() {
      for (final k in m.keys) {
        m['new$k'] = 1;
      }
    }, throwsA(isA<ConcurrentModificationError>()));
  });

  test('records whose keys are out of order encode by name', () {
    final reversed = Map.fromEntries(valid().entries.toList().reversed);
    expect(codec.encode(reversed), codec.encode(valid()));
  });
}
