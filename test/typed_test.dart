import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

/// A record class written by hand the way the generator writes one.
final class Memo {
  const Memo({required this.text, this.written});

  final String text;
  final DateTime? written;

  static final AvroType<Memo> avroType = AvroType<Memo>(
    schemaJson:
        '{"type": "record", "name": "Memo", "namespace": "com.example", "doc": "A memo.", '
        '"fields": [{"name": "text", "type": "string"}, '
        '{"name": "written", "type": ["null", {"type": "long", "logicalType": "timestamp-millis"}]}]}',
    toAvro: (m) => {'text': m.text, 'written': m.written},
    fromAvro: (v) {
      final m = v! as Map<String, Object?>;
      return Memo(
        text: m['text']! as String,
        written: m['written'] as DateTime?,
      );
    },
  );

  @override
  bool operator ==(Object other) =>
      other is Memo && other.text == text && other.written == written;

  @override
  int get hashCode => Object.hash(text, written);
}

void main() {
  final memo = Memo(text: 'Vet', written: DateTime.utc(2025, 11, 15, 10));

  test('the descriptor parses its schema once and keeps the text', () {
    expect(identical(Memo.avroType.schema, Memo.avroType.schema), isTrue);
    expect((Memo.avroType.schema as RecordSchema).doc, 'A memo.');
    expect(Memo.avroType.schema.jsonText, Memo.avroType.schemaJson);
  });

  test('a typed value round-trips, with the bytes of AvroCodec', () {
    final codec = TypedCodec(Memo.avroType);
    final bytes = codec.encode(memo);
    expect(
      bytes,
      AvroCodec(writer: Memo.avroType.schema)
          .encode(Memo.avroType.toAvro(memo)),
    );
    expect(codec.decode(bytes), memo);
    expect(
      codec.decode(codec.encode(const Memo(text: 'x'))),
      const Memo(text: 'x'),
    );
  });

  test('single-object encoding carries the type schema fingerprint', () {
    final codec = TypedCodec(Memo.avroType);
    final bytes = codec.encodeSingleObject(memo);
    expect(
      SingleObjectHeader.parse(bytes).fingerprint,
      Memo.avroType.schema.crc64,
    );
    expect(codec.decodeSingleObject(bytes), memo);
  });

  test('data of an older writer schema is resolved into the type', () {
    final older = Schema.parse(
      '{"type": "record", "name": "Memo", "namespace": "com.example", '
      '"fields": [{"name": "text", "type": "string"}, {"name": "gone", "type": "int"}]}',
    );
    final bytes = AvroCodec(writer: older).encode({'text': 'old', 'gone': 1});
    final codec = TypedCodec(Memo.avroType, writer: older);
    expect(codec.decode(bytes), const Memo(text: 'old'));
    // Encoding still uses the type's own schema.
    expect(TypedCodec(Memo.avroType).decode(codec.encode(memo)), memo);
  });

  test('a writer that does not resolve throws ResolutionException', () {
    expect(
      () => TypedCodec(Memo.avroType, writer: Schema.parse('"int"')),
      throwsA(isA<ResolutionException>()),
    );
  });

  test('the underlying codec writes and reads container files', () {
    final codec = TypedCodec(Memo.avroType);
    final writer = AvroFileWriter(codec.avro)..add(Memo.avroType.toAvro(memo));
    final file = AvroFileReader(writer.close());
    expect(file.records(codec.avro).map(Memo.avroType.fromAvro).toList(), [
      memo,
    ]);
  });

  test('limits apply to typed decoding', () {
    final codec = TypedCodec(
      Memo.avroType,
      limits: const AvroLimits(maxValueDepth: 0),
    );
    expect(
      () => codec.decode(Uint8List.fromList([0, 0])),
      throwsA(isA<LimitExceededException>()),
    );
  });
}
