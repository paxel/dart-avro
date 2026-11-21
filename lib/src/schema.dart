import 'dart:convert';
import 'dart:typed_data';

import 'codec.dart' show Branch;
import 'exceptions.dart';
import 'limits.dart';
import 'logical.dart';

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
  /// Named types may refer to themselves. Throws [SchemaParseException] if the text is not
  /// JSON or not a valid Avro schema, and [LimitExceededException] if it exceeds the schema
  /// limits of [limits].
  factory Schema.parse(
    String jsonText, {
    AvroLimits limits = const AvroLimits(),
  }) {
    final maxBytes = limits.maxSchemaBytes;
    if (maxBytes != null) {
      final size = utf8.encode(jsonText).length;
      if (size > maxBytes) {
        throw LimitExceededException(
          'the schema has $size bytes, the limit is $maxBytes',
          limit: 'maxSchemaBytes',
        );
      }
    }
    final maxDepth = limits.maxSchemaDepth;
    if (maxDepth != null) {
      checkJsonNesting(
        jsonText,
        maxDepth,
        () => throw LimitExceededException(
          'the schema is nested deeper than $maxDepth',
          limit: 'maxSchemaDepth',
        ),
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw SchemaParseException('not JSON: ${e.message}');
    }
    final schema = _Parser().parse(decoded, null, r'$');
    schema._text = jsonText;
    return schema;
  }

  /// The JSON value this schema was parsed from. For a reference to a named type defined
  /// elsewhere, it is the definition's JSON value.
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

/// A record, an enum or a fixed: a type with a full name.
sealed class NamedSchema extends Schema {
  NamedSchema({
    required this.name,
    required this.namespace,
    required List<String> aliases,
    required this.doc,
    required super.json,
    super.props,
  }) : aliases = List.unmodifiable(aliases);

  /// The name without its namespace.
  final String name;

  /// The namespace, or null for the null namespace.
  final String? namespace;

  /// The full names of the aliases.
  final List<String> aliases;

  /// The documentation, if any.
  final String? doc;

  /// The namespace and the name, joined by a dot.
  String get fullName => namespace == null ? name : '$namespace.$name';
}

/// A record (or an error, which is encoded like a record).
final class RecordSchema extends NamedSchema {
  RecordSchema({
    required super.name,
    required super.namespace,
    required super.aliases,
    required super.doc,
    required super.json,
    required this.type,
    super.props,
  });

  /// `record`, or `error` for the records of a protocol's errors.
  @override
  final String type;

  late final List<Field> _fields;

  /// The fields, in the order they are encoded.
  List<Field> get fields => _fields;
}

/// A field of a record.
final class Field {
  Field({
    required this.name,
    required this.schema,
    required this.doc,
    required List<String> aliases,
    required this.order,
    required this.hasDefault,
    required this.defaultValue,
    required this.json,
    Map<String, Object?> props = const {},
  }) : aliases = List.unmodifiable(aliases),
       props = Map.unmodifiable(props);

  final String name;

  /// The schema of the field's values.
  final Schema schema;

  final String? doc;

  /// The field's aliases, as given.
  final List<String> aliases;

  /// `ascending`, `descending` or `ignore`.
  final String order;

  /// Whether the field has a default value.
  final bool hasDefault;

  /// The default value as a Dart value of [schema]; null without a default.
  final Object? defaultValue;

  /// The JSON value the field was parsed from.
  final Map<String, Object?> json;

  /// The attributes the Avro specification does not define, such as `axt.unit`.
  final Map<String, Object?> props;
}

/// An enum: a value is one of [symbols].
final class EnumSchema extends NamedSchema {
  EnumSchema({
    required super.name,
    required super.namespace,
    required super.aliases,
    required super.doc,
    required super.json,
    required List<String> symbols,
    required this.defaultSymbol,
    super.props,
  }) : symbols = List.unmodifiable(symbols);

  @override
  String get type => 'enum';

  final List<String> symbols;

  /// The symbol a reader uses for a writer's symbol it does not know; null if none.
  final String? defaultSymbol;
}

/// A fixed: a value is exactly [size] bytes.
final class FixedSchema extends NamedSchema {
  FixedSchema({
    required super.name,
    required super.namespace,
    required super.aliases,
    required super.doc,
    required super.json,
    required this.size,
    super.props,
  });

  @override
  String get type => 'fixed';

  final int size;
}

/// An array of [items].
final class ArraySchema extends Schema {
  ArraySchema(this.items, {required super.json, super.props});

  @override
  String get type => 'array';

  final Schema items;
}

/// A map from strings to [values].
final class MapSchema extends Schema {
  MapSchema(this.values, {required super.json, super.props});

  @override
  String get type => 'map';

  final Schema values;
}

/// A union: a value is one of [branches].
final class UnionSchema extends Schema {
  UnionSchema(List<Schema> branches, {required super.json})
    : branches = List.unmodifiable(branches);

  @override
  String get type => 'union';

  final List<Schema> branches;
}

/// The name a branch of a union is known by: the full name of a named type, the type name
/// of any other.
String branchName(Schema s) => s is NamedSchema ? s.fullName : s.type;

/// Whether a value of [branch] of [union] decodes into a [Branch] when branches are decoded:
/// when it is not `null` and the union has two or more branches that are not.
bool decodesAsBranch(UnionSchema union, Schema branch) =>
    branch.type != 'null' &&
    union.branches.where((b) => b.type != 'null').length > 1;

/// Keys of a schema object that the specification defines; every other key is a prop.
const _schemaKeys = {
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
  'logicalType',
};

const _fieldKeys = {'name', 'type', 'doc', 'aliases', 'order', 'default'};

Map<String, Object?> _propsOf(Map<String, Object?> object, Set<String> keys) =>
    {
      for (final e in object.entries)
        if (!keys.contains(e.key)) e.key: e.value,
    };

final _namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Counts the nesting of brackets and braces outside strings, before decoding, so that a
/// deeply nested text cannot exhaust the stack of the JSON decoder. Calls [fail] when the
/// nesting exceeds [maxDepth].
void checkJsonNesting(String text, int maxDepth, Never Function() fail) {
  var depth = 0;
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (c == 0x5c) {
        i++;
      } else if (c == 0x22) {
        inString = false;
      }
    } else if (c == 0x22) {
      inString = true;
    } else if (c == 0x5b || c == 0x7b) {
      depth++;
      if (depth > maxDepth) fail();
    } else if (c == 0x5d || c == 0x7d) {
      depth--;
    }
  }
}

final class _Parser {
  final Map<String, NamedSchema> names = {};

  Never fail(String message, String path) =>
      throw SchemaParseException(message, path: path);

  String? stringOrNull(Map<String, Object?> o, String key, String path) =>
      switch (o[key]) {
        null => null,
        final String s => s,
        final v => fail('"$key" must be a string, not ${jsonEncode(v)}', path),
      };

  Schema parse(Object? json, String? namespace, String path) {
    switch (json) {
      case final String name:
        return primitiveTypeNames.contains(name)
            ? PrimitiveSchema(name, json: json)
            : reference(name, namespace, path);
      case final List<Object?> branches:
        return union(branches, namespace, path);
      case final Map<String, Object?> object:
        return switch (object['type']) {
          final String t when primitiveTypeNames.contains(t) => PrimitiveSchema(
            t,
            json: json,
            props: _propsOf(object, _schemaKeys),
          ),
          'record' || 'error' => record(object, namespace, path),
          'enum' => enumeration(object, namespace, path),
          'fixed' => fixed(object, namespace, path),
          'array' => ArraySchema(
            parse(need(object, 'items', path), namespace, '$path.items'),
            json: json,
            props: _propsOf(object, _schemaKeys),
          ),
          'map' => MapSchema(
            parse(need(object, 'values', path), namespace, '$path.values'),
            json: json,
            props: _propsOf(object, _schemaKeys),
          ),
          null => fail('a schema object needs a "type"', path),
          // A type given as a schema itself, as in {"type": {"type": "array", ...}}, or a
          // reference to a named type.
          final Object type => parse(type, namespace, '$path.type'),
        };
      default:
        fail('not a schema: ${jsonEncode(json)}', path);
    }
  }

  Object? need(Map<String, Object?> o, String key, String path) =>
      o.containsKey(key) ? o[key] : fail('missing "$key"', path);

  NamedSchema reference(String name, String? namespace, String path) {
    final full = name.contains('.') || namespace == null
        ? name
        : '$namespace.$name';
    return names[full] ?? names[name] ?? fail('unknown type "$name"', path);
  }

  Schema union(List<Object?> json, String? namespace, String path) {
    final branches = <Schema>[];
    final seen = <String>{};
    for (var i = 0; i < json.length; i++) {
      final p = '$path[$i]';
      final b = parse(json[i], namespace, p);
      if (b is UnionSchema) fail('a union cannot hold a union', p);
      if (!seen.add(branchName(b))) {
        fail('the union holds ${branchName(b)} twice', p);
      }
      branches.add(b);
    }
    return UnionSchema(branches, json: json);
  }

  /// The name, namespace and alias full names of a named type; registers nothing.
  (String, String?, List<String>) naming(
    Map<String, Object?> o,
    String? enclosing,
    String path,
  ) {
    final rawName = need(o, 'name', path);
    if (rawName is! String) fail('"name" must be a string', path);
    String name;
    String? namespace;
    if (rawName.contains('.')) {
      final i = rawName.lastIndexOf('.');
      namespace = rawName.substring(0, i);
      name = rawName.substring(i + 1);
    } else {
      name = rawName;
      namespace = o.containsKey('namespace')
          ? stringOrNull(o, 'namespace', path)
          : enclosing;
    }
    if (namespace == '') namespace = null;
    if (!_namePattern.hasMatch(name)) fail('invalid name "$name"', path);
    if (namespace != null &&
        !namespace.split('.').every(_namePattern.hasMatch)) {
      fail('invalid namespace "$namespace"', path);
    }
    if (namespace == null && primitiveTypeNames.contains(name)) {
      fail('"$name" is a primitive type and cannot be defined', path);
    }
    final aliases = switch (o['aliases']) {
      null => const <String>[],
      final List<Object?> list when list.every((a) => a is String) => [
        for (final a in list.cast<String>())
          a.contains('.') || namespace == null ? a : '$namespace.$a',
      ],
      _ => fail('"aliases" must be an array of strings', path),
    };
    return (name, namespace, aliases);
  }

  void register(NamedSchema s, String path) {
    if (names.containsKey(s.fullName)) {
      fail('"${s.fullName}" is defined twice', path);
    }
    names[s.fullName] = s;
  }

  RecordSchema record(Map<String, Object?> o, String? enclosing, String path) {
    final (name, namespace, aliases) = naming(o, enclosing, path);
    final schema = RecordSchema(
      name: name,
      namespace: namespace,
      aliases: aliases,
      doc: stringOrNull(o, 'doc', path),
      json: o,
      type: o['type']! as String,
      props: _propsOf(o, _schemaKeys),
    );
    register(schema, path);
    final rawFields = need(o, 'fields', path);
    if (rawFields is! List<Object?>) fail('"fields" must be an array', path);
    final fields = <Field>[];
    final seen = <String>{};
    for (var i = 0; i < rawFields.length; i++) {
      final f = rawFields[i];
      final p = '${schema.fullName}.fields[$i]';
      if (f is! Map<String, Object?>) fail('a field must be an object', p);
      final fieldName = need(f, 'name', p);
      if (fieldName is! String || !_namePattern.hasMatch(fieldName)) {
        fail('invalid field name ${jsonEncode(fieldName)}', p);
      }
      if (!seen.add(fieldName)) fail('the field "$fieldName" is twice', p);
      final fieldSchema = parse(need(f, 'type', p), namespace, '$p.type');
      final order = switch (f['order']) {
        null => 'ascending',
        final String s
            when const {'ascending', 'descending', 'ignore'}.contains(s) =>
          s,
        final v => fail('invalid order ${jsonEncode(v)}', p),
      };
      final hasDefault = f.containsKey('default');
      fields.add(
        Field(
          name: fieldName,
          schema: fieldSchema,
          doc: stringOrNull(f, 'doc', p),
          aliases: switch (f['aliases']) {
            null => const [],
            final List<Object?> list when list.every((a) => a is String) =>
              list.cast<String>(),
            _ => fail('"aliases" must be an array of strings', p),
          },
          order: order,
          hasDefault: hasDefault,
          defaultValue: hasDefault
              ? defaultOf(fieldSchema, f['default'], '$p.default')
              : null,
          json: f,
          props: _propsOf(f, _fieldKeys),
        ),
      );
    }
    schema._fields = List.unmodifiable(fields);
    return schema;
  }

  EnumSchema enumeration(
    Map<String, Object?> o,
    String? enclosing,
    String path,
  ) {
    final (name, namespace, aliases) = naming(o, enclosing, path);
    final raw = need(o, 'symbols', path);
    if (raw is! List<Object?>) fail('"symbols" must be an array', path);
    final symbols = <String>[];
    for (final s in raw) {
      if (s is! String || !_namePattern.hasMatch(s)) {
        fail('invalid symbol ${jsonEncode(s)}', path);
      }
      if (symbols.contains(s)) fail('the symbol "$s" is twice', path);
      symbols.add(s);
    }
    final defaultSymbol = stringOrNull(o, 'default', path);
    if (defaultSymbol != null && !symbols.contains(defaultSymbol)) {
      fail('the default "$defaultSymbol" is not a symbol', path);
    }
    final schema = EnumSchema(
      name: name,
      namespace: namespace,
      aliases: aliases,
      doc: stringOrNull(o, 'doc', path),
      json: o,
      symbols: symbols,
      defaultSymbol: defaultSymbol,
      props: _propsOf(o, _schemaKeys),
    );
    register(schema, path);
    return schema;
  }

  FixedSchema fixed(Map<String, Object?> o, String? enclosing, String path) {
    final (name, namespace, aliases) = naming(o, enclosing, path);
    final size = need(o, 'size', path);
    if (size is! int || size < 0) {
      fail('"size" must be a non-negative integer', path);
    }
    final schema = FixedSchema(
      name: name,
      namespace: namespace,
      aliases: aliases,
      doc: stringOrNull(o, 'doc', path),
      json: o,
      size: size,
      props: _propsOf(o, _schemaKeys),
    );
    register(schema, path);
    return schema;
  }

  /// Converts a field's JSON default to a Dart value of [schema].
  Object? defaultOf(Schema schema, Object? json, String path) {
    final value = defaultValueOf(schema, json);
    if (value case _Invalid()) {
      fail('the default ${jsonEncode(json)} does not fit ${schema.type}', path);
    }
    return value;
  }
}

final class _Invalid {
  const _Invalid();
}

const _invalid = _Invalid();

final class _NoLogicalValue implements Exception {
  const _NoLogicalValue();
}

/// The Dart value of a JSON default of [schema], or [_invalid]. A default of a logical type
/// is given as its underlying type and becomes the logical type's Dart value. With
/// [branches], a value of a union is a [Branch] where [decodesAsBranch] says so.
Object? defaultValueOf(Schema schema, Object? json, {bool branches = false}) {
  final raw = _rawDefault(schema, json, branches);
  final logical = logicalOf(schema);
  if (logical == null || raw is _Invalid) return raw;
  try {
    return fromUnderlying(
      logical,
      schema,
      raw,
      (_) => throw const _NoLogicalValue(),
    );
  } on _NoLogicalValue {
    return _invalid;
  }
}

Object? _rawDefault(Schema schema, Object? json, bool branches) {
  Uint8List? bytesOf(Object? j) {
    if (j is! String) return null;
    final out = Uint8List(j.length);
    for (var i = 0; i < j.length; i++) {
      final c = j.codeUnitAt(i);
      if (c > 0xff) return null;
      out[i] = c;
    }
    return out;
  }

  switch (schema) {
    case PrimitiveSchema(type: 'null'):
      return json == null ? null : _invalid;
    case PrimitiveSchema(type: 'boolean'):
      return json is bool ? json : _invalid;
    case PrimitiveSchema(type: 'int'):
      return json is int && json >= -0x80000000 && json <= 0x7fffffff
          ? json
          : _invalid;
    case PrimitiveSchema(type: 'long'):
      return json is int ? json : _invalid;
    case PrimitiveSchema(type: 'float' || 'double'):
      return json is num ? json.toDouble() : _invalid;
    case PrimitiveSchema(type: 'bytes'):
      return bytesOf(json) ?? _invalid;
    case PrimitiveSchema(type: 'string'):
      return json is String ? json : _invalid;
    case PrimitiveSchema():
      return _invalid;
    case FixedSchema(:final size):
      final b = bytesOf(json);
      return b != null && b.length == size ? b : _invalid;
    case EnumSchema(:final symbols):
      return json is String && symbols.contains(json) ? json : _invalid;
    case ArraySchema(:final items):
      if (json is! List<Object?>) return _invalid;
      final out = <Object?>[];
      for (final j in json) {
        final v = defaultValueOf(items, j, branches: branches);
        if (v is _Invalid) return _invalid;
        out.add(v);
      }
      return out;
    case MapSchema(:final values):
      if (json is! Map<String, Object?>) return _invalid;
      final out = <String, Object?>{};
      for (final e in json.entries) {
        final v = defaultValueOf(values, e.value, branches: branches);
        if (v is _Invalid) return _invalid;
        out[e.key] = v;
      }
      return out;
    case RecordSchema(:final fields):
      if (json is! Map<String, Object?>) return _invalid;
      final out = <String, Object?>{};
      for (final f in fields) {
        final Object? v;
        if (json.containsKey(f.name)) {
          v = defaultValueOf(f.schema, json[f.name], branches: branches);
        } else if (f.hasDefault) {
          v = branches
              ? defaultValueOf(f.schema, f.json['default'], branches: true)
              : f.defaultValue;
        } else {
          return _invalid;
        }
        if (v is _Invalid) return _invalid;
        out[f.name] = v;
      }
      return out;
    case UnionSchema():
      for (final b in schema.branches) {
        final v = defaultValueOf(b, json, branches: branches);
        if (v is _Invalid) continue;
        return branches && decodesAsBranch(schema, b)
            ? Branch(branchName(b), v)
            : v;
      }
      return _invalid;
  }
}
