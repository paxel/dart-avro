import 'dart:convert';
import 'dart:typed_data';

import 'binary.dart';
import 'exceptions.dart';
import 'fingerprint.dart';
import 'json.dart';
import 'limits.dart';
import 'logical.dart';
import 'platform.dart';
import 'resolve.dart';
import 'schema.dart';

/// A value of a union, with the branch it belongs to named explicitly.
///
/// [AvroCodec.encode] needs it only where more than one branch of a union fits a value;
/// [name] is the full name of a named type, or the type name of any other (`int`, `map`, …).
/// A codec with `decodeBranches` decodes unions into it, so the values encode back unchanged.
final class Branch {
  const Branch(this.name, this.value);

  final String name;
  final Object? value;

  @override
  bool operator ==(Object other) =>
      other is Branch && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);

  @override
  String toString() => 'Branch($name, $value)';
}

/// Encodes and decodes values of one writer schema, read as one reader schema.
final class AvroCodec {
  /// A codec for data written with [writer] and read as [reader], which defaults to
  /// [writer]. The resolution of the two is compiled here, once; throws
  /// [ResolutionException] if they do not resolve.
  ///
  /// With [decodeBranches], every value of a union with two or more non-null branches is
  /// decoded as a [Branch] of the reader's branch; `null` and the value of a union of `null`
  /// and one other branch stay plain.
  AvroCodec({
    required this.writer,
    Schema? reader,
    this.limits = const AvroLimits(),
    this.decodeBranches = false,
  }) : reader = reader ?? writer,
       _plan = _planFor(writer, reader, decodeBranches);

  /// The resolution plan of [writer] read as [reader], checking the platform first, so that
  /// dart2js fails before any work is done.
  static Plan? _planFor(Schema writer, Schema? reader, bool branches) {
    checkPlatform();
    return reader == null || identical(reader, writer)
        ? null
        : resolve(writer, reader, branches: branches);
  }

  /// The schema data is encoded with.
  final Schema writer;

  /// The schema values are decoded into.
  final Schema reader;

  /// The limits on the input this codec decodes.
  final AvroLimits limits;

  /// Whether a value of a union with two or more non-null branches is decoded as a [Branch].
  final bool decodeBranches;

  /// How data of the writer schema is read as the reader schema; null when they are one.
  final Plan? _plan;

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

  /// Encodes [value] with the writer schema in Avro's JSON encoding: compact, or indented
  /// with [indent], such as two spaces.
  ///
  /// A union value is written as `null` or as `{"<branch>": value}`, the branch named by its
  /// full name or its type name; `bytes` and `fixed` as strings of the code points 0 to 255,
  /// logical types as their underlying type, and `NaN` and the infinities as the strings
  /// `"NaN"`, `"Infinity"` and `"-Infinity"`. Throws [EncodeException] as [encode] does.
  String encodeJson(Object? value, {String? indent}) =>
      encodeJsonWith(this, value, indent);

  /// Decodes one datum of the writer schema in Avro's JSON encoding, read as the reader
  /// schema as [decode] reads it.
  ///
  /// A union branch may also be named by the simple name of a named type when no other
  /// branch has that name. Throws [DecodeException], with offset 0 and the path of the
  /// value, if [json] is not JSON or not a value of the writer schema: a record must have
  /// exactly its fields, an `int` must fit 32 bits.
  Object? decodeJson(String json) => decodeJsonWith(this, json);

  /// Compares [a] and [b], two values of the writer schema as [encode] takes them, by the
  /// Avro sort order; returns -1, 0 or 1.
  ///
  /// `null`s are equal, `false` is less than `true`, numbers compare by value (`NaN` greater
  /// than every other number and equal to itself, `-0.0` less than `0.0`; a `float` as the
  /// 32-bit value it encodes to), `bytes`, `fixed` and strings (as UTF-8) by their unsigned
  /// bytes, arrays element by element and then by length, enums by the index of their symbol,
  /// unions by the index of their branch and then by value, and records field by field in
  /// the field's `order`: `ascending`, `descending`, or `ignore`, whose values are not looked
  /// at. A value of a logical type compares as the value of the underlying type it encodes
  /// to; a `decimal` therefore by the bytes of its two's complement, not by its number.
  ///
  /// The values are of the writer schema: what [decode] returns for another reader schema
  /// is not. Agrees with [compareBytes] on the encodings of the values. Throws
  /// [EncodeException] if a value compared does not fit the schema, and [ArgumentError] on a
  /// map, which Avro gives no order.
  int compare(Object? a, Object? b) =>
      _ValueComparer(limits).compare(writer, a, b, r'$', 0).sign;

  /// Compares [a] and [b], two encodings of the writer schema, by the Avro sort order of
  /// [compare], without decoding them; returns -1, 0 or 1.
  ///
  /// Reads only as far as the first difference: bytes after it, and bytes after the datums,
  /// are not checked. What it reads it checks as [decode] does, and throws [DecodeException]
  /// if it is not a valid encoding, and [ArgumentError] on a map, which Avro gives no order.
  int compareBytes(Uint8List a, Uint8List b) =>
      _BytesComparer(this, a, b).compare(writer, r'$', 0).sign;
}

/// The header of a datum in single-object encoding: the marker `C3 01` and the writer
/// schema's CRC-64-AVRO fingerprint.
final class SingleObjectHeader {
  const SingleObjectHeader._(this.fingerprint, this.payload);

  /// Reads the header of [bytes] without decoding the datum after it.
  ///
  /// Throws [DecodeException] if [bytes] are shorter than the header or do not start with
  /// the marker.
  factory SingleObjectHeader.parse(Uint8List bytes) {
    if (bytes.length < 10) {
      throw DecodeException(
        'single-object encoding needs 10 bytes of header, got ${bytes.length}',
        offset: 0,
      );
    }
    if (bytes[0] != 0xc3 || bytes[1] != 0x01) {
      throw const DecodeException(
        'not single-object encoding: the marker C3 01 is missing',
        offset: 0,
      );
    }
    return SingleObjectHeader._(
      crc64FromBytes(Uint8List.sublistView(bytes, 2, 10)),
      Uint8List.sublistView(bytes, 10),
    );
  }

  /// The CRC-64-AVRO fingerprint of the writer schema, as the 64-bit pattern in an `int`.
  final int fingerprint;

  /// The datum after the header, a view of the parsed bytes.
  final Uint8List payload;
}

/// Single-object encoding: the datum after a header that names the writer schema.
extension SingleObjectEncoding on AvroCodec {
  /// Encodes [value] in single-object encoding, with the writer schema's fingerprint.
  Uint8List encodeSingleObject(Object? value) {
    final out = BinaryWriter()
      ..writeByte(0xc3)
      ..writeByte(0x01)
      ..writeFixed(crc64ToBytes(writer.crc64));
    encodeInto(this, out, value);
    return out.toBytes();
  }

  /// Decodes a datum in single-object encoding. Throws [DecodeException] if the header is
  /// missing or names another schema than the writer's, or if the datum is not valid.
  Object? decodeSingleObject(Uint8List bytes) {
    final header = SingleObjectHeader.parse(bytes);
    if (header.fingerprint != writer.crc64) {
      throw DecodeException(
        'the fingerprint 0x${BigInt.from(header.fingerprint).toUnsigned(64).toRadixString(16)} is not '
        "the writer schema's",
        offset: 2,
      );
    }
    final input = BinaryReader(bytes, 10);
    final value = decodeFrom(this, input);
    if (input.remaining != 0) {
      input.fail('${input.remaining} bytes left over after the datum');
    }
    return value;
  }
}

/// Encodes [value] with [codec] into [out]; for this package's own framing.
void encodeInto(AvroCodec codec, BinaryWriter out, Object? value) =>
    _Encoder(out, codec.limits).encode(codec.writer, value, r'$', 0);

/// Decodes one datum with [codec] from [input]; for this package's own framing.
Object? decodeFrom(AvroCodec codec, BinaryReader input) {
  final decoder = _Decoder(input, codec.limits, codec.decodeBranches);
  final plan = codec._plan;
  if (plan == null) return decoder.decode(codec.writer, r'$', 0);
  return runPlan(
    plan,
    input,
    decoder.decode,
    decoder.blockCount,
    decoder.checkDepth,
    r'$',
    0,
  );
}

final class _Encoder {
  _Encoder(this.out, this.limits);

  final BinaryWriter out;
  final AvroLimits limits;

  void encode(Schema schema, Object? value, String path, int depth) {
    final maxDepth = limits.maxValueDepth;
    if (maxDepth != null && depth > maxDepth) {
      throw LimitExceededException(
        'the value at $path is nested deeper than $maxDepth',
        limit: 'maxValueDepth',
      );
    }
    Never wrong(String expected) => throw EncodeException(
      'expected $expected for ${branchName(schema)}, got ${value.runtimeType}',
      path: path,
    );
    if (value is Branch && schema is! UnionSchema) wrong('a plain value');
    final logical = logicalOf(schema);
    if (logical != null) {
      encodeRaw(
        schema,
        toUnderlying(logical, schema, value, path),
        path,
        depth,
      );
    } else {
      encodeRaw(schema, value, path, depth);
    }
  }

  void encodeRaw(Schema schema, Object? value, String path, int depth) {
    Never wrong(String expected) => throw EncodeException(
      'expected $expected for ${branchName(schema)}, got ${value.runtimeType}',
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
        if (!_isInt32(value)) {
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
        if (value is! Uint8List) wrong('Uint8List');
        out.writeBytes(value);
      case PrimitiveSchema(type: 'string'):
        if (value is! String) wrong('String');
        checkWellFormed(value, path);
        out.writeString(value);
      case PrimitiveSchema():
        throw StateError('unknown primitive ${schema.type}');
      case FixedSchema(:final size):
        if (value is! Uint8List) wrong('Uint8List');
        if (value.length != size) {
          throw EncodeException(
            'a fixed of $size bytes, got ${value.length}',
            path: path,
          );
        }
        out.writeFixed(value);
      case EnumSchema(:final symbols):
        if (value is! String) wrong('String');
        final i = symbols.indexOf(value);
        if (i < 0) {
          throw EncodeException(
            '"$value" is not a symbol of ${schema.fullName}',
            path: path,
          );
        }
        out.writeLong(i);
      case ArraySchema(:final items):
        if (value is! List<Object?> || value is Uint8List) wrong('List');
        if (value.isNotEmpty) {
          out.writeLong(value.length);
          for (var i = 0; i < value.length; i++) {
            encode(items, value[i], '$path[$i]', depth + 1);
          }
        }
        out.writeLong(0);
      case MapSchema(values: final valueSchema):
        if (value is! Map<String, Object?>) wrong('Map<String, Object?>');
        if (value.isNotEmpty) {
          out.writeLong(value.length);
          for (final e in value.entries) {
            checkWellFormed(e.key, path);
            out.writeString(e.key);
            encode(valueSchema, e.value, '$path.${e.key}', depth + 1);
          }
        }
        out.writeLong(0);
      case RecordSchema(:final fields):
        if (value is! Map<String, Object?>) wrong('Map<String, Object?>');
        for (final key in value.keys) {
          if (!fields.any((f) => f.name == key)) {
            throw EncodeException(
              '"$key" is not a field of ${schema.fullName}',
              path: path,
            );
          }
        }
        for (final f in fields) {
          if (!value.containsKey(f.name)) {
            throw EncodeException(
              'the field "${f.name}" is missing',
              path: path,
            );
          }
          encode(f.schema, value[f.name], '$path.${f.name}', depth + 1);
        }
      case UnionSchema(:final branches):
        final (index, inner) = _branchOf(branches, value, path);
        out.writeLong(index);
        encode(branches[index], inner, path, depth + 1);
    }
  }
}

/// The index of the branch of [branches] that [value] belongs to, and the value inside it:
/// named by a [Branch], or the only branch that fits.
(int, Object?) _branchOf(List<Schema> branches, Object? value, String path) {
  if (value is Branch) {
    final index = branches.indexWhere((b) => branchName(b) == value.name);
    if (index < 0) {
      throw EncodeException(
        'the union has no branch "${value.name}"; it has '
        '${branches.map(branchName).join(', ')}',
        path: path,
      );
    }
    return (index, value.value);
  }
  final fitting = [
    for (var i = 0; i < branches.length; i++)
      if (_fits(branches[i], value)) i,
  ];
  if (fitting.isEmpty) {
    throw EncodeException(
      'no branch of the union fits ${value.runtimeType}; it has '
      '${branches.map(branchName).join(', ')}',
      path: path,
    );
  }
  if (fitting.length > 1) {
    throw EncodeException(
      'more than one branch fits; wrap the value in a Branch of one of '
      '${fitting.map((i) => branchName(branches[i])).join(', ')}',
      path: path,
    );
  }
  return (fitting.single, value);
}

bool _isInt32(int v) => v >= -0x80000000 && v <= 0x7fffffff;

/// Whether [value] belongs to [schema] at a glance: by its Dart type, the size of a fixed,
/// the symbols of an enum and the fields of a record. Used to infer a union's branch.
bool _fits(Schema schema, Object? value) {
  final logical = logicalOf(schema);
  return logical != null
      ? fitsLogical(logical, value)
      : _fitsRaw(schema, value);
}

bool _fitsRaw(Schema schema, Object? value) => switch (schema) {
  PrimitiveSchema(type: 'null') => value == null,
  PrimitiveSchema(type: 'boolean') => value is bool,
  PrimitiveSchema(type: 'int') => value is int && _isInt32(value),
  PrimitiveSchema(type: 'long') => value is int,
  PrimitiveSchema(type: 'float' || 'double') => value is double,
  PrimitiveSchema(type: 'bytes') => value is Uint8List,
  PrimitiveSchema(type: 'string') => value is String,
  PrimitiveSchema() => false,
  FixedSchema(:final size) => value is Uint8List && value.length == size,
  EnumSchema(:final symbols) => value is String && symbols.contains(value),
  ArraySchema() => value is List<Object?> && value is! Uint8List,
  MapSchema() => value is Map<String, Object?>,
  RecordSchema(:final fields) =>
    value is Map<String, Object?> &&
        value.length == fields.length &&
        fields.every((f) => value.containsKey(f.name)),
  UnionSchema() => false,
};

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

final _minSizes = Expando<int>();

/// The fewest bytes a value of [schema] can be encoded in; recursion counts as zero.
int minEncodedSize(Schema schema, [Set<Schema>? visiting]) {
  final cached = _minSizes[schema];
  if (cached != null) return cached;
  final seen = visiting ?? <Schema>{};
  if (!seen.add(schema)) return 0;
  final size = switch (schema) {
    PrimitiveSchema(type: 'null') => 0,
    PrimitiveSchema(type: 'float') => 4,
    PrimitiveSchema(type: 'double') => 8,
    PrimitiveSchema() => 1,
    FixedSchema(:final size) => size,
    EnumSchema() || ArraySchema() || MapSchema() || UnionSchema() => 1,
    RecordSchema(:final fields) => fields.fold(
      0,
      (int sum, f) => sum + minEncodedSize(f.schema, seen),
    ),
  };
  seen.remove(schema);
  if (visiting == null) _minSizes[schema] = size;
  return size;
}

final class _Decoder {
  _Decoder(this.input, this.limits, this.decodeBranches);

  final BinaryReader input;
  final AvroLimits limits;

  /// Whether a union with two or more non-null branches decodes into a [Branch].
  final bool decodeBranches;

  /// The item count of the next block of an array or map, checked against the input.
  int blockCount(Schema itemSchema, int perItemExtra, String path) {
    final start = input.offset;
    var count = input.readLong();
    if (count < 0) {
      if (count == -0x8000000000000000) {
        input.fail('invalid block count', start);
      }
      count = -count;
      input
          .readLength(); // the block's size in bytes, which only skipping needs
    }
    final minSize = minEncodedSize(itemSchema) + perItemExtra;
    if (minSize > 0) {
      if (count > input.remaining ~/ minSize) {
        input.fail(
          'declares $count items, more than the ${input.remaining} bytes left can hold',
          start,
        );
      }
    } else {
      final max = limits.maxZeroSizeItems;
      if (max != null && count > max) {
        throw LimitExceededException(
          'an array declares $count items of zero bytes at $path, the limit is $max',
          limit: 'maxZeroSizeItems',
        );
      }
    }
    return count;
  }

  void checkDepth(String path, int depth) {
    final maxDepth = limits.maxValueDepth;
    if (maxDepth != null && depth > maxDepth) {
      throw LimitExceededException(
        'the value at $path is nested deeper than $maxDepth',
        limit: 'maxValueDepth',
      );
    }
  }

  Object? decode(Schema schema, String path, int depth) {
    checkDepth(path, depth);
    final logical = logicalOf(schema);
    if (logical == null) return decodeRaw(schema, path, depth);
    final start = input.offset;
    return fromUnderlying(
      logical,
      schema,
      decodeRaw(schema, path, depth),
      (message) => throw DecodeException(message, offset: start, path: path),
    );
  }

  Object? decodeRaw(Schema schema, String path, int depth) {
    switch (schema) {
      case PrimitiveSchema(type: 'null'):
        return null;
      case PrimitiveSchema(type: 'boolean'):
        return input.readBoolean();
      case PrimitiveSchema(type: 'int'):
        return input.readInt();
      case PrimitiveSchema(type: 'long'):
        return input.readLong();
      case PrimitiveSchema(type: 'float'):
        return input.readFloat();
      case PrimitiveSchema(type: 'double'):
        return input.readDouble();
      case PrimitiveSchema(type: 'bytes'):
        return input.readBytes();
      case PrimitiveSchema(type: 'string'):
        return input.readString();
      case PrimitiveSchema():
        throw StateError('unknown primitive ${schema.type}');
      case FixedSchema(:final size):
        return input.readFixed(size);
      case EnumSchema(:final symbols):
        final start = input.offset;
        final i = input.readInt();
        if (i < 0 || i >= symbols.length) {
          input.fail('$i is not a symbol of ${schema.fullName}', start);
        }
        return symbols[i];
      case ArraySchema(:final items):
        final out = <Object?>[];
        while (true) {
          final count = blockCount(items, 0, path);
          if (count == 0) return out;
          for (var i = 0; i < count; i++) {
            out.add(decode(items, '$path[${out.length}]', depth + 1));
          }
        }
      case MapSchema(:final values):
        final out = <String, Object?>{};
        while (true) {
          final count = blockCount(values, 1, path);
          if (count == 0) return out;
          for (var i = 0; i < count; i++) {
            final key = input.readString();
            out[key] = decode(values, '$path.$key', depth + 1);
          }
        }
      case RecordSchema(:final fields):
        return <String, Object?>{
          for (final f in fields)
            f.name: decode(f.schema, '$path.${f.name}', depth + 1),
        };
      case UnionSchema(:final branches):
        final start = input.offset;
        final i = input.readInt();
        if (i < 0 || i >= branches.length) {
          input.fail('the union has no branch $i', start);
        }
        final value = decode(branches[i], path, depth + 1);
        return decodeBranches && decodesAsBranch(schema, branches[i])
            ? Branch(branchName(branches[i]), value)
            : value;
    }
  }
}

/// The unsigned lexicographic order of [a] and [b], a shorter prefix first.
int _compareUnsigned(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length.compareTo(b.length);
}

final _float32 = Float32List(1);

/// [v] rounded to the 32-bit float it encodes to.
double _toFloat32(double v) => (_float32..[0] = v)[0];

Never _mapsUnordered(String path) => throw ArgumentError(
  'the map at $path cannot be compared: Avro gives maps no order',
);

/// Compares two values of a schema by the Avro sort order, checking them as [_Encoder] does.
final class _ValueComparer {
  _ValueComparer(this.limits);

  final AvroLimits limits;

  int compare(Schema schema, Object? a, Object? b, String path, int depth) {
    final maxDepth = limits.maxValueDepth;
    if (maxDepth != null && depth > maxDepth) {
      throw LimitExceededException(
        'the value at $path is nested deeper than $maxDepth',
        limit: 'maxValueDepth',
      );
    }
    if (schema is! UnionSchema) {
      for (final v in [a, b]) {
        if (v is Branch) {
          throw EncodeException(
            'expected a plain value for ${branchName(schema)}, got Branch',
            path: path,
          );
        }
      }
    }
    final logical = logicalOf(schema);
    if (logical == null) return compareRaw(schema, a, b, path, depth);
    return compareRaw(
      schema,
      toUnderlying(logical, schema, a, path),
      toUnderlying(logical, schema, b, path),
      path,
      depth,
    );
  }

  int compareRaw(Schema schema, Object? a, Object? b, String path, int depth) {
    Never wrong(Object? value, String expected) => throw EncodeException(
      'expected $expected for ${branchName(schema)}, got ${value.runtimeType}',
      path: path,
    );
    switch (schema) {
      case PrimitiveSchema(type: 'null'):
        if (a != null) wrong(a, 'null');
        if (b != null) wrong(b, 'null');
        return 0;
      case PrimitiveSchema(type: 'boolean'):
        if (a is! bool) wrong(a, 'bool');
        if (b is! bool) wrong(b, 'bool');
        return a == b ? 0 : (a ? 1 : -1);
      case PrimitiveSchema(type: 'int' || 'long'):
        if (a is! int) wrong(a, 'int');
        if (b is! int) wrong(b, 'int');
        if (schema.type == 'int') {
          for (final v in [a, b]) {
            if (!_isInt32(v)) {
              throw EncodeException('$v does not fit 32 bits', path: path);
            }
          }
        }
        return a.compareTo(b);
      case PrimitiveSchema(type: 'float'):
        if (a is! num) wrong(a, 'double');
        if (b is! num) wrong(b, 'double');
        return _toFloat32(a.toDouble()).compareTo(_toFloat32(b.toDouble()));
      case PrimitiveSchema(type: 'double'):
        if (a is! num) wrong(a, 'double');
        if (b is! num) wrong(b, 'double');
        return a.toDouble().compareTo(b.toDouble());
      case PrimitiveSchema(type: 'bytes'):
        if (a is! Uint8List) wrong(a, 'Uint8List');
        if (b is! Uint8List) wrong(b, 'Uint8List');
        return _compareUnsigned(a, b);
      case PrimitiveSchema(type: 'string'):
        if (a is! String) wrong(a, 'String');
        if (b is! String) wrong(b, 'String');
        checkWellFormed(a, path);
        checkWellFormed(b, path);
        return _compareUnsigned(utf8.encode(a), utf8.encode(b));
      case PrimitiveSchema():
        throw StateError('unknown primitive ${schema.type}');
      case FixedSchema(:final size):
        Uint8List fixed(Object? v) {
          if (v is! Uint8List) wrong(v, 'Uint8List');
          if (v.length != size) {
            throw EncodeException(
              'a fixed of $size bytes, got ${v.length}',
              path: path,
            );
          }
          return v;
        }
        return _compareUnsigned(fixed(a), fixed(b));
      case EnumSchema(:final symbols):
        int index(Object? v) {
          if (v is! String) wrong(v, 'String');
          final i = symbols.indexOf(v);
          if (i < 0) {
            throw EncodeException(
              '"$v" is not a symbol of ${schema.fullName}',
              path: path,
            );
          }
          return i;
        }
        return index(a).compareTo(index(b));
      case ArraySchema(:final items):
        if (a is! List<Object?> || a is Uint8List) wrong(a, 'List');
        if (b is! List<Object?> || b is Uint8List) wrong(b, 'List');
        final n = a.length < b.length ? a.length : b.length;
        for (var i = 0; i < n; i++) {
          final c = compare(items, a[i], b[i], '$path[$i]', depth + 1);
          if (c != 0) return c;
        }
        return a.length.compareTo(b.length);
      case MapSchema():
        _mapsUnordered(path);
      case RecordSchema(:final fields):
        Map<String, Object?> record(Object? v) {
          if (v is! Map<String, Object?>) wrong(v, 'Map<String, Object?>');
          for (final key in v.keys) {
            if (!fields.any((f) => f.name == key)) {
              throw EncodeException(
                '"$key" is not a field of ${schema.fullName}',
                path: path,
              );
            }
          }
          return v;
        }
        final ma = record(a);
        final mb = record(b);
        for (final f in fields) {
          if (f.order == 'ignore') continue;
          for (final m in [ma, mb]) {
            if (!m.containsKey(f.name)) {
              throw EncodeException(
                'the field "${f.name}" is missing',
                path: path,
              );
            }
          }
          final c = compare(
            f.schema,
            ma[f.name],
            mb[f.name],
            '$path.${f.name}',
            depth + 1,
          );
          if (c != 0) return f.order == 'descending' ? -c : c;
        }
        return 0;
      case UnionSchema(:final branches):
        final (ia, va) = _branchOf(branches, a, path);
        final (ib, vb) = _branchOf(branches, b, path);
        if (ia != ib) return ia.compareTo(ib);
        return compare(branches[ia], va, vb, path, depth + 1);
    }
  }
}

/// Compares two encodings of a schema by the Avro sort order, reading both side by side and
/// checking what it reads as [_Decoder] does.
final class _BytesComparer {
  _BytesComparer(AvroCodec codec, Uint8List a, Uint8List b)
    : this._(BinaryReader(a), BinaryReader(b), codec.limits);

  _BytesComparer._(this.a, this.b, AvroLimits limits)
    : da = _Decoder(a, limits, false),
      db = _Decoder(b, limits, false);

  final BinaryReader a;
  final BinaryReader b;
  final _Decoder da;
  final _Decoder db;

  /// The index of a symbol or a branch, one of [count]; [invalid] says why another is not.
  static int _index(
    BinaryReader input,
    int count,
    String Function(int i) invalid,
  ) {
    final start = input.offset;
    final i = input.readInt();
    if (i < 0 || i >= count) input.fail(invalid(i), start);
    return i;
  }

  int compare(Schema schema, String path, int depth) {
    da.checkDepth(path, depth);
    switch (schema) {
      case PrimitiveSchema(type: 'null'):
        return 0;
      case PrimitiveSchema(type: 'boolean'):
        final x = a.readBoolean();
        final y = b.readBoolean();
        return x == y ? 0 : (x ? 1 : -1);
      case PrimitiveSchema(type: 'int'):
        return a.readInt().compareTo(b.readInt());
      case PrimitiveSchema(type: 'long'):
        return a.readLong().compareTo(b.readLong());
      case PrimitiveSchema(type: 'float'):
        return a.readFloat().compareTo(b.readFloat());
      case PrimitiveSchema(type: 'double'):
        return a.readDouble().compareTo(b.readDouble());
      case PrimitiveSchema(type: 'bytes' || 'string'):
        final x = a.readView(a.readLength());
        final y = b.readView(b.readLength());
        return _compareUnsigned(x, y);
      case PrimitiveSchema():
        throw StateError('unknown primitive ${schema.type}');
      case FixedSchema(:final size):
        return _compareUnsigned(a.readView(size), b.readView(size));
      case EnumSchema(:final symbols):
        String what(int i) => '$i is not a symbol of ${schema.fullName}';
        final x = _index(a, symbols.length, what);
        return x.compareTo(_index(b, symbols.length, what));
      case ArraySchema(:final items):
        var ra = 0;
        var rb = 0;
        for (var i = 0; ; i++) {
          if (ra == 0) ra = da.blockCount(items, 0, path);
          if (rb == 0) rb = db.blockCount(items, 0, path);
          if (ra == 0 || rb == 0) return ra.compareTo(rb);
          final c = compare(items, '$path[$i]', depth + 1);
          if (c != 0) return c;
          ra--;
          rb--;
        }
      case MapSchema():
        _mapsUnordered(path);
      case RecordSchema(:final fields):
        for (final f in fields) {
          final fieldPath = '$path.${f.name}';
          if (f.order == 'ignore') {
            da.decode(f.schema, fieldPath, depth + 1);
            db.decode(f.schema, fieldPath, depth + 1);
            continue;
          }
          final c = compare(f.schema, fieldPath, depth + 1);
          if (c != 0) return f.order == 'descending' ? -c : c;
        }
        return 0;
      case UnionSchema(:final branches):
        String what(int i) => 'the union has no branch $i';
        final x = _index(a, branches.length, what);
        final y = _index(b, branches.length, what);
        if (x != y) return x.compareTo(y);
        return compare(branches[x], path, depth + 1);
    }
  }
}
