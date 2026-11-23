@Tags(['web'])
library;

import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

import '../support/schema_tests.dart';
import 'files.dart';

void main() {
  group("Apache Avro's schema-tests.txt", () {
    final cases = parseSchemaTests(webText('apache/schema-tests.txt'));

    test('has all its cases', () {
      expect(cases, hasLength(34));
    });

    for (final c in cases) {
      test('case ${c.id}', () {
        final s = Schema.parse(c.input);
        expect(s.canonicalForm, c.canonical);
        if (c.fingerprint != null) expect(s.crc64, c.fingerprint);
      });
    }
  });

  test('the fingerprints of paxel/axt spec/envelope.md, section 10.1', () {
    final envelope = Schema.parse(webText('axt/envelope-canonical.json'));
    final memo = Schema.parse(webText('axt/memo-canonical.json'));
    expect(envelope.crc64, 0xa89eceb9716f3016);
    expect(memo.crc64, 0x37f20e16cadcac73);
    expect(crc64ToBytes(envelope.crc64), [
      0x16,
      0x30,
      0x6f,
      0x71,
      0xb9,
      0xce,
      0x9e,
      0xa8,
    ]);
    expect(crc64FromBytes(crc64ToBytes(memo.crc64)), memo.crc64);
  });

  test('the example message of paxel/axt spec/envelope.md, section 10.2', () {
    final message = webHex('axt/memo-message.hex');
    expect(message, hasLength(210));
    final envelope = AvroCodec(
      writer: Schema.parse(webText('axt/envelope-canonical.json')),
    );
    final memo = AvroCodec(
      writer: Schema.parse(webText('axt/memo-canonical.json')),
    );

    expect(SingleObjectHeader.parse(message).fingerprint, 0xa89eceb9716f3016);
    final value = envelope.decodeSingleObject(message)! as Map<String, Object?>;
    expect(value['kind'], 'DATA');
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

  test("Apache Avro's interop.avsc round-trips, in binary and JSON", () {
    final codec = AvroCodec(
      writer: Schema.parse(webText('apache/interop.avsc')),
    );
    final value = <String, Object?>{
      'intField': 12,
      'longField': -0x8000000000000000,
      'stringField': 'hey',
      'boolField': true,
      'floatField': 1234.0,
      'doubleField': -1234.0,
      'bytesField': Uint8List.fromList([0x31, 0x32]),
      'nullField': null,
      'arrayField': [5.0, 0.0, 12.0],
      'mapField': {
        'a': {'label': 'a'},
        'bee': {'label': 'cee'},
      },
      'unionField': 12.0,
      'enumField': 'C',
      'fixedField': Uint8List.fromList(List.generate(16, (i) => i)),
      'recordField': {
        'label': 'root',
        'children': [
          {'label': 'child', 'children': <Object?>[]},
        ],
      },
    };
    expect(codec.decode(codec.encode(value)), value);
    expect(codec.decodeJson(codec.encodeJson(value)), value);
  });
}
