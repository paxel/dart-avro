import 'dart:typed_data';

import 'binary.dart';
import 'exceptions.dart';
import 'limits.dart';
import 'logical.dart';
import 'resolve.dart';
import 'schema.dart';

/// A value of a union, with the branch it belongs to named explicitly.
///
/// [AvroCodec.encode] needs it only where more than one branch of a union fits a value;
/// [name] is the full name of a named type, or the type name of any other (`int`, `map`, …).
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
  AvroCodec({
    required this.writer,
    Schema? reader,
    this.limits = const AvroLimits(),
  }) : reader = reader ?? writer,
       _plan = reader == null || identical(reader, writer)
           ? null
           : resolve(writer, reader);

  /// The schema data is encoded with.
  final Schema writer;

  /// The schema values are decoded into.
  final Schema reader;

  /// The limits on the input this codec decodes.
  final AvroLimits limits;

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
}

/// Encodes [value] with [codec] into [out]; for this package's own framing.
void encodeInto(AvroCodec codec, BinaryWriter out, Object? value) =>
    _Encoder(out, codec.limits).encode(codec.writer, value, r'$', 0);

/// Decodes one datum with [codec] from [input]; for this package's own framing.
Object? decodeFrom(AvroCodec codec, BinaryReader input) {
  final decoder = _Decoder(input, codec.limits);
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
      throw EncodeException(
        'the value is nested deeper than $maxDepth',
        path: path,
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
        final int index;
        final Object? inner;
        if (value is Branch) {
          index = branches.indexWhere((b) => branchName(b) == value.name);
          if (index < 0) {
            throw EncodeException(
              'the union has no branch "${value.name}"; it has '
              '${branches.map(branchName).join(', ')}',
              path: path,
            );
          }
          inner = value.value;
        } else {
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
          index = fitting.single;
          inner = value;
        }
        out.writeLong(index);
        encode(branches[index], inner, path, depth + 1);
    }
  }
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
  _Decoder(this.input, this.limits);

  final BinaryReader input;
  final AvroLimits limits;

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
        return decode(branches[i], path, depth + 1);
    }
  }
}
