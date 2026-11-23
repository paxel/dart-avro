@Tags(['web'])
library;

import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

Schema s(String json) => Schema.parse(json);

/// Writes [value] with [writer] and reads it back as [reader].
Object? readAs(String writer, String reader, Object? value) {
  final w = s(writer);
  final bytes = AvroCodec(writer: w).encode(value);
  return AvroCodec(writer: w, reader: s(reader)).decode(bytes);
}

Matcher throwsResolution() => throwsA(isA<ResolutionException>());

void main() {
  group('promotions', () {
    test('int to long, float and double', () {
      expect(readAs('"int"', '"long"', 7), 7);
      expect(readAs('"int"', '"float"', 7), 7.0);
      expect(readAs('"int"', '"double"', -7), -7.0);
    });

    test('long to float and double, float to double', () {
      expect(readAs('"long"', '"double"', 1 << 40), (1 << 40).toDouble());
      expect(readAs('"long"', '"float"', 3), 3.0);
      expect(readAs('"float"', '"double"', 1.5), 1.5);
    });

    test('string and bytes both ways', () {
      expect(
        readAs('"string"', '"bytes"', 'hi'),
        Uint8List.fromList([0x68, 0x69]),
      );
      expect(
        readAs('"bytes"', '"string"', Uint8List.fromList([0x68, 0x69])),
        'hi',
      );
    });

    test('no promotion the other way', () {
      expect(
        () => AvroCodec(writer: s('"long"'), reader: s('"int"')),
        throwsResolution(),
      );
      expect(
        () => AvroCodec(writer: s('"double"'), reader: s('"float"')),
        throwsResolution(),
      );
      expect(
        () => AvroCodec(writer: s('"int"'), reader: s('"string"')),
        throwsResolution(),
      );
    });
  });

  group('records', () {
    const writer = '''
{"type": "record", "name": "Memo", "namespace": "a", "fields": [
  {"name": "text", "type": "string"},
  {"name": "gone", "type": {"type": "array", "items": "long"}},
  {"name": "count", "type": "int"}
]}''';

    test('match fields by name, skip what the reader lacks, fill defaults', () {
      const reader = '''
{"type": "record", "name": "Memo", "namespace": "b", "fields": [
  {"name": "count", "type": "long"},
  {"name": "added", "type": "string", "default": "new"},
  {"name": "text", "type": "string"}
]}''';
      final v = readAs(writer, reader, {
        'text': 'hi',
        'gone': [1, 2],
        'count': 3,
      });
      expect(v, {'count': 3, 'added': 'new', 'text': 'hi'});
      expect((v! as Map).keys, ['count', 'added', 'text']);
    });

    test('a field and a record found by their aliases', () {
      const reader = '''
{"type": "record", "name": "Note", "aliases": ["a.Memo"], "fields": [
  {"name": "body", "aliases": ["text"], "type": "string"},
  {"name": "count", "type": "int"}
]}''';
      expect(
        readAs(writer, reader, {'text': 'hi', 'gone': <Object?>[], 'count': 1}),
        {'body': 'hi', 'count': 1},
      );
    });

    test(
      'a reader field without a default that the writer lacks does not resolve',
      () {
        const reader = '''
{"type": "record", "name": "Memo", "fields": [{"name": "missing", "type": "int"}]}''';
        expect(
          () => AvroCodec(writer: s(writer), reader: s(reader)),
          throwsA(
            isA<ResolutionException>().having(
              (e) => e.path,
              'path',
              'Memo.missing',
            ),
          ),
        );
      },
    );

    test('records of another name do not resolve', () {
      expect(
        () => AvroCodec(
          writer: s(writer),
          reader: s('{"type": "record", "name": "Other", "fields": []}'),
        ),
        throwsResolution(),
      );
    });

    test('defaults are copied, not shared', () {
      const reader = '''
{"type": "record", "name": "Memo", "fields": [
  {"name": "list", "type": {"type": "array", "items": "int"}, "default": [1]}
]}''';
      final codec = AvroCodec(writer: s(writer), reader: s(reader));
      final bytes = AvroCodec(writer: s(writer))
          .encode({'text': '', 'gone': <Object?>[], 'count': 0});
      final first = codec.decode(bytes)! as Map<String, Object?>;
      (first['list']! as List<Object?>).add(2);
      expect(codec.decode(bytes), {
        'list': [1],
      });
    });

    test('recursive records resolve', () {
      const w = '''
{"type": "record", "name": "L", "fields": [
  {"name": "v", "type": "int"}, {"name": "next", "type": ["null", "L"]}]}''';
      const r = '''
{"type": "record", "name": "L", "fields": [
  {"name": "v", "type": "long"}, {"name": "next", "type": ["null", "L"]},
  {"name": "tag", "type": "string", "default": "t"}]}''';
      expect(
        readAs(w, r, {
          'v': 1,
          'next': {'v': 2, 'next': null},
        }),
        {
          'v': 1,
          'next': {'v': 2, 'next': null, 'tag': 't'},
          'tag': 't',
        },
      );
    });
  });

  group('enums', () {
    const writer = '{"type": "enum", "name": "E", "symbols": ["A", "B", "C"]}';

    test('symbols are matched by name', () {
      expect(
        readAs(
          writer,
          '{"type": "enum", "name": "E", "symbols": ["C", "B", "A"]}',
          'A',
        ),
        'A',
      );
    });

    test('an unknown symbol takes the reader default', () {
      expect(
        readAs(
          writer,
          '{"type": "enum", "name": "E", "symbols": ["A", "X"], "default": "X"}',
          'C',
        ),
        'X',
      );
    });

    test('an unknown symbol without a default fails when it is read', () {
      final codec = AvroCodec(
        writer: s(writer),
        reader: s('{"type": "enum", "name": "E", "symbols": ["A"]}'),
      );
      expect(codec.decode(AvroCodec(writer: s(writer)).encode('A')), 'A');
      expect(
        () => codec.decode(AvroCodec(writer: s(writer)).encode('B')),
        throwsResolution(),
      );
    });
  });

  group('unions', () {
    test('a writer union into a plain reader', () {
      expect(readAs('["null", "int"]', '"long"', 4), 4);
      final codec = AvroCodec(
        writer: s('["null", "int"]'),
        reader: s('"long"'),
      );
      expect(() => codec.decode(Uint8List.fromList([0])), throwsResolution());
    });

    test('a plain writer into the first matching reader branch', () {
      expect(readAs('"int"', '["null", "string", "long", "double"]', 4), 4);
      expect(readAs('"float"', '["null", "double"]', 1.5), 1.5);
    });

    test("a reader union takes Java's branch: same type, then a promotion", () {
      expect(readAs('"int"', '["null", "double", "long", "int"]', 5), 5);
      expect(readAs('"int"', '["null", "double", "long"]', 5), 5.0);
      expect(readAs('"long"', '["null", "double", "long"]', 5), 5);
      expect(readAs('"string"', '["bytes", "string"]', 'a'), 'a');
    });

    test('a reader union prefers the same full name, then a resolving record', () {
      const w =
          '{"type": "record", "name": "a.R", "fields": [{"name": "x", "type": "int"}]}';
      const twoRecords = '''
[{"type": "record", "name": "b.R", "fields": [{"name": "y", "type": "int"}]},
 {"type": "record", "name": "c.R", "fields": [{"name": "x", "type": "long"}]},
 {"type": "record", "name": "a.R", "fields": [{"name": "x", "type": "int"},
   {"name": "z", "type": "int", "default": 9}]}]''';
      expect(readAs(w, twoRecords, {'x': 1}), {'x': 1, 'z': 9});
      const noFullName = '''
[{"type": "record", "name": "b.R", "fields": [{"name": "y", "type": "int"}]},
 {"type": "record", "name": "c.R", "fields": [{"name": "x", "type": "long"}]}]''';
      expect(readAs(w, noFullName, {'x': 1}), {'x': 1});
    });

    test('union to union', () {
      expect(readAs('["null", "int"]', '["long", "null"]', null), isNull);
      expect(readAs('["null", "int"]', '["long", "null"]', 9), 9);
    });

    test('a writer union of which no branch resolves does not resolve', () {
      expect(
        () => AvroCodec(writer: s('["null", "boolean"]'), reader: s('"int"')),
        throwsResolution(),
      );
    });
  });

  test('arrays, maps and fixed resolve recursively', () {
    expect(
      readAs(
        '{"type": "array", "items": "int"}',
        '{"type": "array", "items": "double"}',
        [1, 2],
      ),
      [1.0, 2.0],
    );
    expect(
      readAs(
        '{"type": "map", "values": "int"}',
        '{"type": "map", "values": "long"}',
        {'a': 1},
      ),
      {'a': 1},
    );
    expect(
      () => AvroCodec(
        writer: s('{"type": "fixed", "name": "F", "size": 2}'),
        reader: s('{"type": "fixed", "name": "F", "size": 3}'),
      ),
      throwsResolution(),
    );
  });

  test('the reader logical type applies to the underlying value', () {
    expect(
      readAs(
        '"long"',
        '{"type": "long", "logicalType": "timestamp-millis"}',
        0,
      ),
      DateTime.utc(1970),
    );
    expect(
      readAs(
        '{"type": "long", "logicalType": "timestamp-millis"}',
        '"long"',
        DateTime.utc(1970, 1, 1, 0, 0, 1),
      ),
      1000,
    );
  });

  test('decimals of another scale do not resolve', () {
    expect(
      () => AvroCodec(
        writer: s(
          '{"type": "bytes", "logicalType": "decimal", "precision": 4, "scale": 2}',
        ),
        reader: s(
          '{"type": "bytes", "logicalType": "decimal", "precision": 4, "scale": 1}',
        ),
      ),
      throwsResolution(),
    );
  });

  test('encode on a resolving codec writes with the writer schema', () {
    final codec = AvroCodec(writer: s('"int"'), reader: s('"long"'));
    expect(codec.encode(1), [2]);
    expect(() => codec.encode(1 << 40), throwsA(isA<EncodeException>()));
  });
}
