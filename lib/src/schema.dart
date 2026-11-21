import 'dart:convert';

import 'exceptions.dart';
import 'limits.dart';

/// The names of Avro's primitive types.
const primitiveTypeNames = {
  'null',
  'boolean',
  'int',
  'long',
  'float',
  'double',
  'bytes',
  'string',
};

/// An Avro schema, parsed from its JSON.
sealed class Schema {
  Schema({required this.json, Map<String, Object?> props = const {}})
    : props = Map.unmodifiable(props);

  /// Parses a schema from its JSON text.
  ///
  /// Throws [SchemaParseException] if the text is not JSON or not a valid Avro schema.
  factory Schema.parse(
    String jsonText, {
    AvroLimits limits = const AvroLimits(),
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw SchemaParseException('not JSON: ${e.message}');
    }
    final schema = _Parser(limits).parse(decoded, null);
    schema._text = jsonText;
    return schema;
  }

  /// The JSON value this schema was parsed from.
  final Object? json;

  /// The attributes the Avro specification does not define, such as `axt.title`.
  final Map<String, Object?> props;

  String? _text;

  /// The JSON text of the schema: the text it was parsed from at the root, its JSON value
  /// encoded again for a nested schema.
  String get jsonText => _text ?? jsonEncode(json);

  /// The name of the Avro type: `int`, `record`, `array`, …
  String get type;

  /// The logical type, if the schema carries one.
  String? get logicalType => switch (json) {
    {'logicalType': final String t} => t,
    _ => null,
  };
}

/// One of the primitive types: `null`, `boolean`, `int`, `long`, `float`, `double`, `bytes`
/// or `string`.
final class PrimitiveSchema extends Schema {
  PrimitiveSchema(this.type, {required super.json, super.props});

  @override
  final String type;
}

/// Keys of a schema object that the specification defines; every other key is a prop.
const _reservedKeys = {
  'type',
  'name',
  'namespace',
  'doc',
  'aliases',
  'fields',
  'symbols',
  'items',
  'values',
  'size',
  'default',
  'order',
  'logicalType',
};

Map<String, Object?> propsOf(
  Map<String, Object?> object,
  Set<String> reserved,
) => {
  for (final e in object.entries)
    if (!reserved.contains(e.key)) e.key: e.value,
};

final class _Parser {
  _Parser(this.limits);

  final AvroLimits limits;

  Schema parse(Object? json, String? path) {
    switch (json) {
      case final String name when primitiveTypeNames.contains(name):
        return PrimitiveSchema(name, json: json);
      case final String name:
        throw SchemaParseException('unknown type "$name"', path: path);
      case {'type': final String name} when primitiveTypeNames.contains(name):
        final object = json as Map<String, Object?>;
        return PrimitiveSchema(
          name,
          json: json,
          props: propsOf(object, _reservedKeys),
        );
      case {'type': final Object? type}:
        throw SchemaParseException(
          'unknown type ${jsonEncode(type)}',
          path: path,
        );
      case Map():
        throw SchemaParseException(
          'a schema object needs a "type"',
          path: path,
        );
      default:
        throw SchemaParseException(
          'not a schema: ${jsonEncode(json)}',
          path: path,
        );
    }
  }
}
