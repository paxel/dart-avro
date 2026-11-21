// The JSON encoding of Avro (ADR 9): values as field defaults are written, with a union as
// null or {"<branch>": value} and NaN and the infinities as strings.
//
// Both directions go through the binary encoding of the writer schema: encodeJson encodes
// the value as `encode` does and turns the bytes into JSON; decodeJson turns the JSON into
// bytes and decodes them as `decode` does, resolution and logical types included.

import 'dart:convert';
import 'dart:typed_data';

import 'binary.dart';
import 'codec.dart';
import 'exceptions.dart';
import 'schema.dart';

/// The JSON text of [value], encoded with [codec]'s writer schema.
String encodeJsonWith(AvroCodec codec, Object? value, String? indent) {
  final bytes = codec.encode(value);
  final json = _toJson(codec.writer, BinaryReader(bytes));
  return (indent == null ? const JsonEncoder() : JsonEncoder.withIndent(indent))
      .convert(json);
}

/// The value of the JSON [text] of [codec]'s writer schema, read as its reader schema.
Object? decodeJsonWith(AvroCodec codec, String text) {
  final maxDepth = codec.limits.maxValueDepth;
  if (maxDepth != null) {
    // The JSON of a value is nested one level deeper than the value: its root is a level.
    checkJsonNesting(
      text,
      maxDepth + 1,
      () => throw LimitExceededException(
        'the JSON value is nested deeper than $maxDepth',
        limit: 'maxValueDepth',
      ),
    );
  }
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    throw DecodeException('not JSON: ${e.message}', offset: 0);
  }
  final out = BinaryWriter();
  _toBinary(codec.writer, json, r'$', out);
  try {
    return codec.decode(out.toBytes());
  } on DecodeException catch (e) {
    // The bytes exist only in memory; for JSON the position is the path alone.
    throw DecodeException(e.message, offset: 0, path: e.path);
  }
}

/// The JSON value of one datum of [schema], read from bytes this package has just encoded.
Object? _toJson(Schema schema, BinaryReader input) {
  switch (schema) {
    case PrimitiveSchema(type: 'null'):
      return null;
    case PrimitiveSchema(type: 'boolean'):
      return input.readBoolean();
    case PrimitiveSchema(type: 'int' || 'long'):
      return input.readLong();
    case PrimitiveSchema(type: 'float'):
      return _shortestFloat(input.readFloat());
    case PrimitiveSchema(type: 'double'):
      return _special(input.readDouble());
    case PrimitiveSchema(type: 'bytes'):
      return String.fromCharCodes(input.readBytes());
    case PrimitiveSchema(type: 'string'):
      return input.readString();
    case PrimitiveSchema():
      throw StateError('unknown primitive ${schema.type}');
    case FixedSchema(:final size):
      return String.fromCharCodes(input.readFixed(size));
    case EnumSchema(:final symbols):
      return symbols[input.readLong()];
    case ArraySchema(:final items):
      final out = <Object?>[];
      for (var count = input.readLong(); count != 0; count = input.readLong()) {
        for (var i = 0; i < count; i++) {
          out.add(_toJson(items, input));
        }
      }
      return out;
    case MapSchema(:final values):
      final out = <String, Object?>{};
      for (var count = input.readLong(); count != 0; count = input.readLong()) {
        for (var i = 0; i < count; i++) {
          final key = input.readString();
          out[key] = _toJson(values, input);
        }
      }
      return out;
    case RecordSchema(:final fields):
      return <String, Object?>{
        for (final f in fields) f.name: _toJson(f.schema, input),
      };
    case UnionSchema(:final branches):
      final branch = branches[input.readLong()];
      if (branch is PrimitiveSchema && branch.type == 'null') return null;
      return {branchName(branch): _toJson(branch, input)};
  }
}

/// NaN and the infinities as the strings JSON has for them; any other double as itself.
Object _special(double v) => v.isNaN
    ? 'NaN'
    : v == double.infinity
    ? 'Infinity'
    : v == double.negativeInfinity
    ? '-Infinity'
    : v;

/// The double with the fewest significant digits that is the same float, so that the float
/// 0.1 is written as 0.1, not as the 0.10000000149011612 it is as a double.
Object _shortestFloat(double v) {
  if (!v.isFinite) return _special(v);
  final float = Float32List(1);
  for (var digits = 1; digits <= 9; digits++) {
    final candidate = double.parse(v.toStringAsPrecision(digits));
    float[0] = candidate;
    if (float[0] == v) return candidate;
  }
  return v;
}

/// Writes the binary encoding of the JSON value [json] of [schema] to [out].
void _toBinary(Schema schema, Object? json, String path, BinaryWriter out) {
  Never fail(String message) =>
      throw DecodeException(message, offset: 0, path: path);
  Never wrong(String expected) => fail(
    'expected $expected for ${branchName(schema)}, got ${_describe(json)}',
  );

  switch (schema) {
    case PrimitiveSchema(type: 'null'):
      if (json != null) wrong('null');
    case PrimitiveSchema(type: 'boolean'):
      if (json is! bool) wrong('true or false');
      out.writeBoolean(json);
    case PrimitiveSchema(type: 'int'):
      if (json is! int) wrong('an integer');
      if (json < -0x80000000 || json > 0x7fffffff) {
        fail('$json does not fit 32 bits');
      }
      out.writeLong(json);
    case PrimitiveSchema(type: 'long'):
      if (json is! int) wrong('an integer of 64 bits');
      out.writeLong(json);
    case PrimitiveSchema(type: 'float'):
      out.writeFloat(_number(json, wrong));
    case PrimitiveSchema(type: 'double'):
      out.writeDouble(_number(json, wrong));
    case PrimitiveSchema(type: 'bytes'):
      if (json is! String) wrong('a string');
      out.writeBytes(_bytes(json, fail));
    case PrimitiveSchema(type: 'string'):
      if (json is! String) wrong('a string');
      _checkWellFormed(json, fail);
      out.writeString(json);
    case PrimitiveSchema():
      throw StateError('unknown primitive ${schema.type}');
    case FixedSchema(:final size):
      if (json is! String) wrong('a string');
      final bytes = _bytes(json, fail);
      if (bytes.length != size) {
        fail('a fixed of $size bytes, got ${bytes.length}');
      }
      out.writeFixed(bytes);
    case EnumSchema(:final symbols):
      if (json is! String) wrong('a string');
      final i = symbols.indexOf(json);
      if (i < 0) fail('"$json" is not a symbol of ${schema.fullName}');
      out.writeLong(i);
    case ArraySchema(:final items):
      if (json is! List<Object?>) wrong('an array');
      if (json.isNotEmpty) {
        out.writeLong(json.length);
        for (var i = 0; i < json.length; i++) {
          _toBinary(items, json[i], '$path[$i]', out);
        }
      }
      out.writeLong(0);
    case MapSchema(:final values):
      if (json is! Map<String, Object?>) wrong('an object');
      if (json.isNotEmpty) {
        out.writeLong(json.length);
        for (final MapEntry(:key, :value) in json.entries) {
          _checkWellFormed(key, fail);
          out.writeString(key);
          _toBinary(values, value, '$path.$key', out);
        }
      }
      out.writeLong(0);
    case RecordSchema(:final fields):
      if (json is! Map<String, Object?>) wrong('an object');
      for (final key in json.keys) {
        if (!fields.any((f) => f.name == key)) {
          fail('"$key" is not a field of ${schema.fullName}');
        }
      }
      for (final f in fields) {
        if (!json.containsKey(f.name)) fail('the field "${f.name}" is missing');
        _toBinary(f.schema, json[f.name], '$path.${f.name}', out);
      }
    case UnionSchema(:final branches):
      if (json == null) {
        final i = branches.indexWhere(
          (b) => b is PrimitiveSchema && b.type == 'null',
        );
        if (i < 0) fail('the union has no null branch');
        out.writeLong(i);
        return;
      }
      if (json is! Map<String, Object?> || json.length != 1) {
        fail(
          'a union value is null or an object with one key, its branch; got '
          '${_describe(json)}',
        );
      }
      final MapEntry(:key, :value) = json.entries.single;
      final i = _branchIndex(branches, key, fail);
      out.writeLong(i);
      _toBinary(branches[i], value, path, out);
  }
}

/// The branch named [key]: its full name or type name, or the simple name of exactly one
/// named branch.
int _branchIndex(
  List<Schema> branches,
  String key,
  Never Function(String) fail,
) {
  final exact = branches.indexWhere((b) => branchName(b) == key);
  if (exact >= 0) return exact;
  final simple = [
    for (var i = 0; i < branches.length; i++)
      if (branches[i] case NamedSchema(:final name) when name == key) i,
  ];
  if (simple.length == 1) return simple.single;
  final names = branches.map(branchName).join(', ');
  if (simple.length > 1) {
    fail(
      '"$key" names more than one branch of the union; use the full name of one of $names',
    );
  }
  fail('the union has no branch "$key"; it has $names');
}

double _number(Object? json, Never Function(String) wrong) => switch (json) {
  num() => json.toDouble(),
  'NaN' => double.nan,
  'Infinity' => double.infinity,
  '-Infinity' => double.negativeInfinity,
  _ => wrong('a number, "NaN", "Infinity" or "-Infinity"'),
};

/// The bytes of a string of code points 0 to 255.
Uint8List _bytes(String json, Never Function(String) fail) {
  final bytes = Uint8List(json.length);
  for (var i = 0; i < json.length; i++) {
    final c = json.codeUnitAt(i);
    if (c > 0xff) {
      fail(
        'bytes are code points 0 to 255; index $i is ${c.toRadixString(16)}',
      );
    }
    bytes[i] = c;
  }
  return bytes;
}

void _checkWellFormed(String value, Never Function(String) fail) {
  try {
    checkWellFormed(value, '');
  } on EncodeException catch (e) {
    fail('a string is not well-formed: ${e.message}');
  }
}

String _describe(Object? json) => switch (json) {
  null => 'null',
  bool() => 'a boolean',
  int() => 'the integer $json',
  num() => 'the number $json',
  String() => 'a string',
  List<Object?>() => 'an array',
  _ => 'an object',
};
