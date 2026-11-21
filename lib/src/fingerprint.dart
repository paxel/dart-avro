import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'schema.dart';

const _empty = 0xc15d213aa4d7a795;

final List<int> _table = List.generate(256, (i) {
  var fp = i;
  for (var j = 0; j < 8; j++) {
    fp = (fp >>> 1) ^ (_empty & -(fp & 1));
  }
  return fp;
}, growable: false);

/// The CRC-64-AVRO (Rabin) fingerprint of [bytes], as the 64-bit pattern in an `int`.
int crc64Avro(List<int> bytes) {
  var fp = _empty;
  for (final b in bytes) {
    fp = (fp >>> 8) ^ _table[(fp ^ b) & 0xff];
  }
  return fp;
}

/// The 8 little-endian bytes of a CRC-64-AVRO fingerprint, as Avro writes it.
Uint8List crc64ToBytes(int fingerprint) =>
    Uint8List(8)..buffer.asByteData().setInt64(0, fingerprint, Endian.little);

/// The CRC-64-AVRO fingerprint held in 8 little-endian bytes.
int crc64FromBytes(List<int> bytes) {
  if (bytes.length != 8) {
    throw ArgumentError.value(bytes, 'bytes', 'must be 8 bytes');
  }
  return ByteData.sublistView(Uint8List.fromList(bytes))
      .getInt64(0, Endian.little);
}

final _canonical = Expando<String>();

/// The Parsing Canonical Form of a schema and its fingerprints.
extension SchemaFingerprints on Schema {
  /// The Parsing Canonical Form, as the Avro specification defines it.
  String get canonicalForm =>
      _canonical[this] ??= _Canonical().write(this).toString();

  /// The CRC-64-AVRO fingerprint of the canonical form, as the 64-bit pattern in an `int`.
  int get crc64 => crc64Avro(utf8.encode(canonicalForm));

  /// The MD5 fingerprint of the canonical form.
  Uint8List get md5 =>
      Uint8List.fromList(crypto.md5.convert(utf8.encode(canonicalForm)).bytes);

  /// The SHA-256 fingerprint of the canonical form.
  Uint8List get sha256 => Uint8List.fromList(
    crypto.sha256.convert(utf8.encode(canonicalForm)).bytes,
  );
}

final class _Canonical {
  final StringBuffer out = StringBuffer();
  final Set<String> written = {};

  StringBuffer write(Schema s) {
    switch (s) {
      case PrimitiveSchema(:final type):
        out.write(jsonEncode(type));
      case NamedSchema(:final fullName) when !written.add(fullName):
        out.write(jsonEncode(fullName));
      case RecordSchema(:final fullName, :final fields):
        out.write('{"name":${jsonEncode(fullName)},"type":"record","fields":[');
        for (var i = 0; i < fields.length; i++) {
          if (i > 0) out.write(',');
          out.write('{"name":${jsonEncode(fields[i].name)},"type":');
          write(fields[i].schema);
          out.write('}');
        }
        out.write(']}');
      case EnumSchema(:final fullName, :final symbols):
        out.write(
          '{"name":${jsonEncode(fullName)},"type":"enum",'
          '"symbols":${jsonEncode(symbols)}}',
        );
      case FixedSchema(:final fullName, :final size):
        out.write(
          '{"name":${jsonEncode(fullName)},"type":"fixed","size":$size}',
        );
      case ArraySchema(:final items):
        out.write('{"type":"array","items":');
        write(items);
        out.write('}');
      case MapSchema(:final values):
        out.write('{"type":"map","values":');
        write(values);
        out.write('}');
      case UnionSchema(:final branches):
        out.write('[');
        for (var i = 0; i < branches.length; i++) {
          if (i > 0) out.write(',');
          write(branches[i]);
        }
        out.write(']');
    }
    return out;
  }
}
