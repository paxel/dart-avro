// Needs dart:io, or test data read from files: not one of the web tests.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:avro/avro.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

import 'support/schema_tests.dart';

void main() {
  final cases = parseSchemaTests(
    File('test/data/apache/schema-tests.txt').readAsStringSync(),
  );

  test('all cases of schema-tests.txt are read', () {
    expect(cases, hasLength(34));
  });

  group("Apache Avro's schema-tests.txt", () {
    for (final c in cases) {
      test('case ${c.id}', () {
        final s = Schema.parse(c.input);
        expect(s.canonicalForm, c.canonical);
        if (c.fingerprint != null) expect(s.crc64, c.fingerprint);
      });
    }
  });

  test('the fingerprints of paxel/axt spec/envelope.md, section 10.1', () {
    final envelope = Schema.parse(
      File('test/data/axt/envelope-canonical.json').readAsStringSync(),
    );
    final memo = Schema.parse(
      File('test/data/axt/memo-canonical.json').readAsStringSync(),
    );
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

  test('a logical type and every other attribute are dropped', () {
    final s = Schema.parse(
      '{"type": "record", "name": "R", "namespace": "n", "doc": "d", "x": 1, '
      '"fields": [{"name": "u", "type": {"type": "string", "logicalType": "uuid"}, '
      '"default": "123e4567-e89b-12d3-a456-426614174000", "doc": "d", "order": "ignore"}]}',
    );
    expect(
      s.canonicalForm,
      '{"name":"n.R","type":"record","fields":[{"name":"u","type":"string"}]}',
    );
  });

  test('MD5 and SHA-256 are over the canonical form', () {
    final s = Schema.parse('{"type": "fixed", "name": "F", "size": 16}');
    final bytes = utf8.encode(s.canonicalForm);
    expect(s.md5, crypto.md5.convert(bytes).bytes);
    expect(s.sha256, crypto.sha256.convert(bytes).bytes);
    expect(s.sha256, hasLength(32));
  });

  test('crc64FromBytes needs 8 bytes', () {
    expect(() => crc64FromBytes([1, 2]), throwsArgumentError);
  });
}
