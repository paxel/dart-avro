import 'dart:typed_data';

import 'binary.dart';
import 'exceptions.dart';
import 'limits.dart';
import 'schema.dart';

/// Encodes and decodes values of one writer schema, read as one reader schema.
final class AvroCodec {
  /// A codec for data written with [writer]. [reader] defaults to [writer].
  AvroCodec({
    required this.writer,
    Schema? reader,
    this.limits = const AvroLimits(),
  }) : reader = reader ?? writer;

  /// The schema data is encoded with.
  final Schema writer;

  /// The schema values are decoded into.
  final Schema reader;

  /// The limits on the input this codec decodes.
  final AvroLimits limits;

  /// Encodes [value] with the writer schema.
  ///
  /// Throws [EncodeException] if the value does not fit the schema.
  Uint8List encode(Object? value) {
    final out = BinaryWriter();
    encodeInto(this, out, value);
    return out.toBytes();
  }

  /// Decodes one datum. Throws [DecodeException] if the bytes are not a valid encoding or if
  /// bytes are left over after the datum.
  Object? decode(Uint8List bytes) {
    final input = BinaryReader(bytes);
    final value = decodeFrom(this, input);
    if (input.remaining != 0) {
      input.fail('${input.remaining} bytes left over after the datum');
    }
    return value;
  }
}

/// Encodes [value] with [codec] into [out]; for this package's own framing.
void encodeInto(AvroCodec codec, BinaryWriter out, Object? value) =>
    _encode(codec.writer, value, out, r'$');

/// Decodes one datum with [codec] from [input]; for this package's own framing.
Object? decodeFrom(AvroCodec codec, BinaryReader input) =>
    _decode(codec.writer, input);

void _encode(Schema schema, Object? value, BinaryWriter out, String path) {
  Never wrong(String expected) => throw EncodeException(
    'expected $expected for ${schema.type}, got ${value.runtimeType}',
    path: path,
  );
  switch (schema) {
    case PrimitiveSchema(type: 'null'):
      if (value != null) wrong('null');
    case PrimitiveSchema(type: 'boolean'):
      if (value is! bool) wrong('bool');
      out.writeBoolean(value);
    case PrimitiveSchema(type: 'int'):
      if (value is! int) wrong('int');
      if (value < -0x80000000 || value > 0x7fffffff) {
        throw EncodeException('$value does not fit 32 bits', path: path);
      }
      out.writeLong(value);
    case PrimitiveSchema(type: 'long'):
      if (value is! int) wrong('int');
      out.writeLong(value);
    case PrimitiveSchema(type: 'float'):
      if (value is! num) wrong('double');
      out.writeFloat(value.toDouble());
    case PrimitiveSchema(type: 'double'):
      if (value is! num) wrong('double');
      out.writeDouble(value.toDouble());
    case PrimitiveSchema(type: 'bytes'):
      if (value is! List<int>) wrong('Uint8List');
      out.writeBytes(value);
    case PrimitiveSchema(type: 'string'):
      if (value is! String) wrong('String');
      checkWellFormed(value, path);
      out.writeString(value);
    case PrimitiveSchema():
      throw StateError('unknown primitive ${schema.type}');
  }
}

/// Throws [EncodeException] if [value] holds an unpaired surrogate, which UTF-8 cannot encode.
void checkWellFormed(String value, String path) {
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      if (i + 1 < value.length) {
        final d = value.codeUnitAt(i + 1);
        if (d >= 0xdc00 && d <= 0xdfff) {
          i++;
          continue;
        }
      }
      throw EncodeException('unpaired surrogate at index $i', path: path);
    }
    if (c >= 0xdc00 && c <= 0xdfff) {
      throw EncodeException('unpaired surrogate at index $i', path: path);
    }
  }
}

Object? _decode(Schema schema, BinaryReader input) => switch (schema) {
  PrimitiveSchema(type: 'null') => null,
  PrimitiveSchema(type: 'boolean') => input.readBoolean(),
  PrimitiveSchema(type: 'int') => input.readInt(),
  PrimitiveSchema(type: 'long') => input.readLong(),
  PrimitiveSchema(type: 'float') => input.readFloat(),
  PrimitiveSchema(type: 'double') => input.readDouble(),
  PrimitiveSchema(type: 'bytes') => input.readBytes(),
  PrimitiveSchema(type: 'string') => input.readString(),
  PrimitiveSchema() => throw StateError('unknown primitive ${schema.type}'),
};
