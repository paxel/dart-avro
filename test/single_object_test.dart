import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

Uint8List hexFile(String path) {
  final hex = File(path).readAsStringSync().trim();
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

Schema schemaFile(String path) => Schema.parse(File(path).readAsStringSync());

void main() {
  final codec = AvroCodec(writer: Schema.parse('"string"'));

  test('the header is C3 01 and the fingerprint, then the datum', () {
    final bytes = codec.encodeSingleObject('a');
    expect(bytes.sublist(0, 2), [0xc3, 0x01]);
    expect(bytes.sublist(2, 10), crc64ToBytes(codec.writer.crc64));
    expect(bytes.sublist(10), [2, 0x61]);
    expect(codec.decodeSingleObject(bytes), 'a');
  });

  test('the header can be read without decoding', () {
    final header = SingleObjectHeader.parse(codec.encodeSingleObject('a'));
    expect(header.fingerprint, codec.writer.crc64);
    expect(header.payload, [2, 0x61]);
  });

  group('rejected', () {
    test('a missing marker', () {
      final bytes = codec.encodeSingleObject('a')..[0] = 0;
      expect(
        () => codec.decodeSingleObject(bytes),
        throwsA(isA<DecodeException>()),
      );
      expect(
        () => SingleObjectHeader.parse(bytes),
        throwsA(isA<DecodeException>()),
      );
    });

    test('a short header', () {
      expect(
        () => SingleObjectHeader.parse(Uint8List.fromList([0xc3, 0x01, 0])),
        throwsA(isA<DecodeException>()),
      );
    });

    test("another schema's fingerprint", () {
      final other = AvroCodec(writer: Schema.parse('"bytes"'));
      expect(
        () => codec.decodeSingleObject(other.encodeSingleObject(Uint8List(1))),
        throwsA(isA<DecodeException>()),
      );
    });

    test('bytes left over', () {
      final bytes = Uint8List.fromList([...codec.encodeSingleObject('a'), 0]);
      expect(
        () => codec.decodeSingleObject(bytes),
        throwsA(isA<DecodeException>()),
      );
    });
  });

  test('the example message of paxel/axt spec/envelope.md, section 10.2', () {
    final message = hexFile('test/data/axt/memo-message.hex');
    expect(message, hasLength(210));
    final envelope = AvroCodec(
      writer: schemaFile('test/data/axt/envelope-canonical.json'),
    );
    final memo = AvroCodec(
      writer: schemaFile('test/data/axt/memo-canonical.json'),
    );

    expect(SingleObjectHeader.parse(message).fingerprint, 0xa89eceb9716f3016);
    final value = envelope.decodeSingleObject(message)! as Map<String, Object?>;
    expect(value['format'], 1);
    expect(value['kind'], 'DATA');
    expect(value['record'], {
      'id': '0b5a3c1e-4d2f-4a6b-9c8d-7e6f5a4b3c2d',
      'version': 1,
    });

    final body = value['body']! as Uint8List;
    expect(SingleObjectHeader.parse(body).fingerprint, 0x37f20e16cadcac73);
    final text = memo.decodeSingleObject(body)! as Map<String, Object?>;
    expect(text['text'], 'Vet, Tuesday 10:00');
    expect(
      (text['written']! as Map<String, Object?>)['instant_ms'],
      1763200800000,
    );

    expect(memo.encodeSingleObject(text), body);
    expect(envelope.encodeSingleObject(value), message);
  });
}
