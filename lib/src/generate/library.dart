/// Writes the Dart library of the generated classes.
library;

import 'dart:convert';

import '../exceptions.dart';
import '../fingerprint.dart';
import '../limits.dart';
import '../logical.dart';
import '../schema.dart';
import 'naming.dart';

/// Why the generator stops: a message naming the file it concerns.
final class GenerateException implements Exception {
  GenerateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A schema file: its path as given and its text.
typedef SchemaFile = ({String path, String text});

/// The Dart library of the classes of every record and the enums of every enum in [files].
///
/// A full name defined in several files gets one Dart type when the definitions have the same
/// canonical form; the first definition is used, and [warn] is told if the others differ in
/// their docs or attributes. The types of a namespace in [prefixes] get its prefix before
/// their names. Throws [GenerateException] if a file is not a valid schema, two definitions
/// differ, or a name cannot be generated.
String generateLibrary(
  List<SchemaFile> files, {
  Map<String, String> prefixes = const {},
  void Function(String message)? warn,
}) {
  final classes = <_Class>[];
  final first = <String, ({NamedSchema schema, String path})>{};
  final classOf = <NamedSchema, _Class>{};
  final classNames = <String, NamedSchema>{};
  final usedPrefixes = <String>{};
  for (final file in files) {
    final Schema root;
    try {
      root = Schema.parse(file.text, limits: AvroLimits.none);
    } on SchemaParseException catch (e) {
      throw GenerateException('${file.path}: $e');
    }
    for (final named in _namedTypes(root)) {
      final earlier = first[named.fullName];
      if (earlier != null) {
        if (named.canonicalForm != earlier.schema.canonicalForm) {
          throw GenerateException(
            '${file.path}: "${named.fullName}" is defined differently in '
            '${earlier.path}',
          );
        }
        if (_ownJson(named) != _ownJson(earlier.schema)) {
          warn?.call(
            '"${named.fullName}" in ${file.path} differs from ${earlier.path} in its '
            'docs or attributes; the definition in ${earlier.path} is used',
          );
        }
        final c = classOf[earlier.schema];
        if (c != null) classOf[named] = c;
        continue;
      }
      first[named.fullName] = (schema: named, path: file.path);
      if (named is FixedSchema) continue;
      final simple = className(named.name);
      if (simple == null) {
        throw GenerateException(
          '${file.path}: the ${named.type} "${named.fullName}" has no Dart name',
        );
      }
      final prefix = prefixes[named.namespace];
      if (prefix != null) usedPrefixes.add(named.namespace!);
      final name = '${prefix ?? ''}$simple';
      if (clashingTypeNames.contains(name)) {
        throw GenerateException(
          '${file.path}: the Dart name $name of "${named.fullName}" would clash with '
          '$name of dart:core, dart:typed_data or package:avro; '
          '${_suggestion([named], prefixes)}',
        );
      }
      final other = classNames[name];
      if (other != null) {
        throw GenerateException(
          '${file.path}: "${named.fullName}" and "${other.fullName}" '
          '(${first[other.fullName]!.path}) both give the Dart name $name; '
          '${_suggestion([named, other], prefixes)}',
        );
      }
      classNames[name] = named;
      final c = _Class(
        named,
        name,
        named is! RecordSchema
            ? ''
            : identical(named, root)
            ? file.text
            : _selfContained(named, file.path),
        file.path,
      );
      classes.add(c);
      classOf[named] = c;
    }
  }
  for (final namespace in prefixes.keys) {
    if (!usedPrefixes.contains(namespace)) {
      warn?.call(
        'no record or enum is in the namespace $namespace of --prefix',
      );
    }
  }
  final out = _Library(classOf);
  for (final c in classes) {
    switch (c.schema) {
      case final RecordSchema schema:
        out.writeClass(c, schema);
      case final EnumSchema schema:
        out.writeEnum(c, schema);
      case FixedSchema():
    }
  }
  return out.finish(files);
}

/// How to resolve a clash of the Dart names of [types]: the `--prefix` to add for the
/// namespace of the first of them that has none.
String _suggestion(List<NamedSchema> types, Map<String, String> prefixes) {
  for (final t in types) {
    final namespace = t.namespace;
    if (namespace != null && !prefixes.containsKey(namespace)) {
      final prefix = [
        for (final part in namespace.split('.')) className(part) ?? '',
      ].join();
      return 'add --prefix $namespace=$prefix';
    }
  }
  return 'rename one of them, or choose other prefixes';
}

/// The JSON of a named type's own definition, with every named type in it given by its full
/// name and the keys sorted: two definitions of one canonical form differ in their docs or
/// attributes if this differs.
String _ownJson(NamedSchema type) {
  Object? sorted(Object? json) => switch (json) {
    final Map<String, Object?> map => {
      for (final key in map.keys.toList()..sort()) key: sorted(map[key]),
    },
    final List<Object?> list => [for (final e in list) sorted(e)],
    _ => json,
  };
  Object? json(Schema s, {bool root = false}) {
    switch (s) {
      case NamedSchema() when !root:
        return s.fullName;
      case NamedSchema():
        final out = {...s.json! as Map<String, Object?>}..remove('namespace');
        out['name'] = s.fullName;
        out['aliases'] = s.aliases;
        if (s is RecordSchema) {
          out['fields'] = [
            for (final f in s.fields) {...f.json, 'type': json(f.schema)},
          ];
        }
        return out;
      case ArraySchema(:final items):
        return {...s.json! as Map<String, Object?>, 'items': json(items)};
      case MapSchema(:final values):
        return {...s.json! as Map<String, Object?>, 'values': json(values)};
      case UnionSchema(:final branches):
        return [for (final b in branches) json(b)];
      case PrimitiveSchema():
        return s.json;
    }
  }

  return jsonEncode(sorted(json(type, root: true)));
}

/// The named types of [root], each once, in the order of their definitions.
List<NamedSchema> _namedTypes(Schema root) {
  final out = <NamedSchema>[];
  final seen = Set<NamedSchema>.identity();
  void visit(Schema s) {
    switch (s) {
      case NamedSchema() when !seen.add(s):
        return;
      case RecordSchema(:final fields):
        out.add(s);
        for (final f in fields) {
          visit(f.schema);
        }
      case NamedSchema():
        out.add(s);
      case ArraySchema(:final items):
        visit(items);
      case MapSchema(:final values):
        visit(values);
      case UnionSchema(:final branches):
        branches.forEach(visit);
      case PrimitiveSchema():
    }
  }

  visit(root);
  return out;
}

/// The JSON text of a named type defined inside another, standing on its own: every named
/// type in it is defined at its first occurrence, with its namespace given, and referred to by
/// its full name after that.
String _selfContained(NamedSchema type, String path) {
  final seen = Set<NamedSchema>.identity();
  Object? json(Schema s) {
    switch (s) {
      case NamedSchema() when !seen.add(s):
        return s.fullName;
      case NamedSchema():
        final original = s.json! as Map<String, Object?>;
        final out = <String, Object?>{};
        for (final e in original.entries) {
          out[e.key] = switch (e.key) {
            'name' => s.name,
            'namespace' => s.namespace ?? '',
            'fields' when s is RecordSchema => [
              for (final f in s.fields)
                {
                  for (final fe in f.json.entries)
                    fe.key: fe.key == 'type' ? json(f.schema) : fe.value,
                },
            ],
            _ => e.value,
          };
          if (e.key == 'name') out['namespace'] = s.namespace ?? '';
        }
        return out;
      case ArraySchema(:final items):
        return {
          for (final e in (s.json! as Map<String, Object?>).entries)
            e.key: e.key == 'items' ? json(items) : e.value,
        };
      case MapSchema(:final values):
        return {
          for (final e in (s.json! as Map<String, Object?>).entries)
            e.key: e.key == 'values' ? json(values) : e.value,
        };
      case UnionSchema(:final branches):
        return [for (final b in branches) json(b)];
      case PrimitiveSchema():
        return s.json;
    }
  }

  final text = const JsonEncoder.withIndent('  ').convert(json(type));
  String? problem;
  try {
    final parsed = Schema.parse(text, limits: AvroLimits.none);
    if (parsed.canonicalForm != type.canonicalForm) {
      problem = 'its canonical form differs';
    }
  } on SchemaParseException catch (e) {
    problem = '$e';
  }
  if (problem != null) {
    throw GenerateException(
      '$path: the JSON of "${type.fullName}" on its own does not give its schema: $problem',
    );
  }
  return text;
}

final class _Class {
  _Class(this.schema, this.name, this.schemaJson, this.path);

  /// A record or an enum.
  final NamedSchema schema;
  final String name;

  /// The JSON text of a record's schema; empty for an enum, which has no descriptor.
  final String schemaJson;
  final String path;
}

/// A field of a generated class.
final class _Field {
  _Field(this.avro, this.name, this.type, this.place);

  final Field avro;
  final String name;

  /// The name of the sealed class of a union in the field, before `Item` and `Value`.
  final String place;

  /// The Dart type, or null for a field of the type `null`, which gets no Dart field.
  final String? type;

  bool get nullable => type == 'Object?' || type!.endsWith('?');

  /// Whether `==` needs the deep comparison of lists and maps.
  bool get deep =>
      type!.startsWith('List<') ||
      type!.startsWith('Map<') ||
      type!.startsWith('Uint8List') ||
      type == 'Object?';
}

/// The sealed class of a union with two or more non-null branches, at one place of use.
final class _Sealed {
  _Sealed(this.name, this.union, this.doc);

  final String name;
  final UnionSchema union;

  /// Where the union is, for the doc comment: the field and the class of the record.
  final String doc;

  /// The class of each non-null branch: its name, the branch and the Dart type of its value.
  late final List<({String name, Schema schema, String type})> branches;

  bool get nullable => union.branches.any((b) => b.type == 'null');
}

final class _Library {
  _Library(this.classOf) {
    for (final c in classOf.values) {
      owners[c.name] = '"${c.schema.fullName}"';
    }
  }

  final Map<NamedSchema, _Class> classOf;
  final StringBuffer body = StringBuffer();
  bool usesTypedData = false;
  bool usesDeep = false;

  /// What each generated Dart type name is taken by, to stop at a clash.
  final Map<String, String> owners = {};

  /// The sealed classes by name, and those still to be written after the current record.
  final Map<String, _Sealed> sealed = {};
  final List<_Sealed> pending = [];

  /// The file and the field whose type is being worked out, for the messages of clashes.
  String path = '';
  String where = '';
  String docWhere = '';

  /// Takes the Dart type name [name] for [what]; throws [GenerateException] if it is taken.
  void claim(String name, String what) {
    if (clashingTypeNames.contains(name)) {
      throw GenerateException(
        '$path: the Dart name $name of $what would clash with $name of dart:core, '
        'dart:typed_data or package:avro',
      );
    }
    final other = owners[name];
    if (other != null) {
      throw GenerateException(
        '$path: $what and $other both give the Dart name $name',
      );
    }
    owners[name] = what;
  }

  /// The sealed class of [u], named [name], declared on first use.
  _Sealed sealedOf(UnionSchema u, String name) {
    final known = sealed[name];
    if (known != null && identical(known.union, u)) return known;
    claim(name, 'the union in $where');
    final out = _Sealed(name, u, docWhere);
    sealed[name] = out;
    pending.add(out);
    out.branches = [
      for (final b in u.branches)
        if (b.type != 'null') _branchClass(name, b),
    ];
    return out;
  }

  ({String name, Schema schema, String type}) _branchClass(
    String sealedName,
    Schema b,
  ) {
    final String part;
    if (b is NamedSchema) {
      final simple = className(b.name);
      if (simple == null) {
        throw GenerateException(
          '$path: the branch "${b.fullName}" of the union in $where has no Dart name',
        );
      }
      part = simple;
    } else {
      part = b.type[0].toUpperCase() + b.type.substring(1);
    }
    final name = '$sealedName$part';
    claim(name, 'the branch "${branchName(b)}" of the union in $where');
    return (name: name, schema: b, type: typeOf(b, name));
  }

  String finish(List<SchemaFile> files) {
    final out = StringBuffer()
      ..writeln('// Generated by avro:generate. Do not edit.')
      ..writeln('//')
      ..writeln('// From:');
    for (final f in files) {
      out.writeln('// - ${f.path.replaceAll(r'\', '/')}');
    }
    out.writeln();
    if (usesTypedData) out.writeln("import 'dart:typed_data';");
    out
      ..writeln("import 'package:avro/avro.dart';")
      ..writeln()
      ..write(body);
    if (usesDeep) out.write(_deepHelpers);
    return out.toString();
  }

  /// The Dart type of [s]; [place] names the sealed class of a union with two or more
  /// non-null branches in it.
  String typeOf(Schema s, String place) {
    final logical = logicalOf(s);
    if (logical != null) {
      return switch (logical) {
        Logical.decimal || Logical.bigDecimal => 'AvroDecimal',
        Logical.uuid => 'String',
        Logical.date => 'AvroDate',
        Logical.timeMillis || Logical.timeMicros => 'Duration',
        Logical.timestampMillis || Logical.timestampMicros => 'DateTime',
        Logical.timestampNanos => 'AvroTimestampNanos',
        Logical.localTimestampMillis ||
        Logical.localTimestampMicros ||
        Logical.localTimestampNanos => 'AvroLocalTimestamp',
        Logical.duration => 'AvroDuration',
      };
    }
    switch (s) {
      case PrimitiveSchema(type: 'null'):
        return 'Null';
      case PrimitiveSchema(type: 'boolean'):
        return 'bool';
      case PrimitiveSchema(type: 'int' || 'long'):
        return 'int';
      case PrimitiveSchema(type: 'float' || 'double'):
        return 'double';
      case PrimitiveSchema(type: 'string'):
        return 'String';
      case PrimitiveSchema(type: 'bytes') || FixedSchema():
        usesTypedData = true;
        return 'Uint8List';
      case PrimitiveSchema():
        throw StateError('unknown primitive ${s.type}');
      case EnumSchema():
        return classOf[s]!.name;
      case ArraySchema(:final items):
        return 'List<${typeOf(items, '${place}Item')}>';
      case MapSchema(:final values):
        return 'Map<String, ${typeOf(values, '${place}Value')}>';
      case RecordSchema():
        return classOf[s]!.name;
      case UnionSchema():
        if (_isWide(s)) {
          final sealed = sealedOf(s, place);
          return sealed.nullable ? '${sealed.name}?' : sealed.name;
        }
        final inner = _nullableBranch(s);
        return inner == null ? 'Object?' : '${typeOf(inner, place)}?';
    }
  }

  /// The generic value of a Dart value [e] of [s], or null if it is the Dart value itself;
  /// [place] as for [typeOf].
  String? toAvro(Schema s, String e, int depth, String place) {
    if (logicalOf(s) != null) return null;
    switch (s) {
      case RecordSchema():
        return '${classOf[s]!.name}.avroType.toAvro($e)';
      case ArraySchema(:final items):
        final x = 'x$depth';
        final inner = toAvro(items, x, depth + 1, '${place}Item');
        return inner == null ? null : '[for (final $x in $e) $inner]';
      case MapSchema(:final values):
        final x = 'x$depth';
        final inner = toAvro(values, '$x.value', depth + 1, '${place}Value');
        return inner == null
            ? null
            : '{for (final $x in $e.entries) $x.key: $inner}';
      case UnionSchema() when _isWide(s):
        final sealed = sealedOf(s, place);
        final v = 'v$depth';
        final cases = [
          for (final b in sealed.branches)
            '${b.name}(value: final $v) => '
                "Branch('${branchName(b.schema)}', "
                '${toAvro(b.schema, v, depth + 1, b.name) ?? v})',
          if (sealed.nullable) 'null => null',
        ];
        return 'switch ($e) { ${cases.join(', ')} }';
      case UnionSchema():
        final branch = _nullableBranch(s);
        if (branch == null) return null;
        final v = 'v$depth';
        final inner = toAvro(branch, v, depth + 1, place);
        return inner == null
            ? null
            : 'switch ($e) { final $v? => $inner, null => null }';
      case EnumSchema():
        return '$e.symbol';
      case PrimitiveSchema() || FixedSchema():
        return null;
    }
  }

  /// The Dart value of [s] for a generic value [e]; [place] as for [typeOf].
  String fromAvro(Schema s, String e, int depth, String place) {
    if (logicalOf(s) != null) return '$e as ${typeOf(s, place)}';
    switch (s) {
      case RecordSchema():
        return '${classOf[s]!.name}.avroType.fromAvro($e)';
      case ArraySchema(:final items):
        final x = 'x$depth';
        return '[for (final $x in $e as List<Object?>) '
            '${fromAvro(items, x, depth + 1, '${place}Item')}]';
      case MapSchema(:final values):
        final x = 'x$depth';
        return '{for (final $x in ($e as Map<String, Object?>).entries) '
            '$x.key: ${fromAvro(values, '$x.value', depth + 1, '${place}Value')}}';
      case UnionSchema() when _isWide(s):
        final sealed = sealedOf(s, place);
        final v = 'v$depth';
        final cases = [
          for (final b in sealed.branches)
            "Branch(name: '${branchName(b.schema)}', value: final $v) => "
                '${b.name}(${fromAvro(b.schema, v, depth + 1, b.name)})',
          if (sealed.nullable) 'null => null',
          "_ => throw ArgumentError.value($e, 'value', "
              "'not a branch of ${sealed.name}')",
        ];
        return 'switch ($e) { ${cases.join(', ')} }';
      case UnionSchema():
        final branch = _nullableBranch(s);
        if (branch == null) return e;
        final type = typeOf(branch, place);
        if (_isCast(branch)) return '$e as $type?';
        final v = 'v$depth';
        return 'switch ($e) { final $v? => ${fromAvro(branch, v, depth + 1, place)}, '
            'null => null }';
      case EnumSchema():
        return '${classOf[s]!.name}.fromSymbol($e as String)';
      case PrimitiveSchema() || FixedSchema():
        return '$e as ${typeOf(s, place)}';
    }
  }

  /// Whether [fromAvro] of [s] is a cast.
  bool _isCast(Schema s) =>
      logicalOf(s) != null || s is PrimitiveSchema || s is FixedSchema;

  void writeEnum(_Class c, EnumSchema schema) {
    if (schema.symbols.isEmpty) {
      throw GenerateException(
        '${c.path}: the enum "${schema.fullName}" has no symbols, and a Dart enum needs one',
      );
    }
    final n = c.name;
    final names = <String, String>{};
    for (final symbol in schema.symbols) {
      final name = enumValueName(symbol);
      if (name == null) {
        throw GenerateException(
          '${c.path}: the symbol "$symbol" of "${schema.fullName}" has no Dart name',
        );
      }
      final other = names.entries.where((e) => e.value == name).firstOrNull;
      if (other != null) {
        throw GenerateException(
          '${c.path}: the symbols "${other.key}" and "$symbol" of '
          '"${schema.fullName}" both give the Dart name $name',
        );
      }
      names[symbol] = name;
    }
    final b = body;
    _doc(b, schema.doc, '');
    b.writeln('enum $n {');
    final values = [for (final e in names.entries) "  ${e.value}('${e.key}')"]
        .join(',\n');
    b.writeln('$values;');
    b
      ..writeln()
      ..writeln('  const $n(this.symbol);')
      ..writeln()
      ..writeln('  /// The Avro symbol of the value.')
      ..writeln('  final String symbol;')
      ..writeln()
      ..writeln(
        '  /// The value of the Avro symbol [symbol]. Throws [ArgumentError] for any '
        'other string.',
      )
      ..writeln('  static $n fromSymbol(String symbol) => switch (symbol) {');
    for (final e in names.entries) {
      b.writeln("    '${e.key}' => ${e.value},");
    }
    b
      ..writeln(
        "    _ => throw ArgumentError.value(symbol, 'symbol', 'not a symbol of $n'),",
      )
      ..writeln('  };')
      ..writeln('}')
      ..writeln();
  }

  void writeClass(_Class c, RecordSchema schema) {
    final fields = <_Field>[];
    final byName = <String, Field>{};
    for (final f in schema.fields) {
      final name = fieldName(f.name);
      if (name == null) {
        throw GenerateException(
          '${c.path}: the field "${f.name}" of "${schema.fullName}" has no Dart name',
        );
      }
      final other = byName[name];
      if (other != null) {
        throw GenerateException(
          '${c.path}: the fields "${other.name}" and "${f.name}" of '
          '"${schema.fullName}" both give the Dart name $name',
        );
      }
      byName[name] = f;
      final isNull = f.schema is PrimitiveSchema && f.schema.type == 'null';
      final place = className(f.name);
      if (place == null) {
        throw GenerateException(
          '${c.path}: the field "${f.name}" of "${schema.fullName}" has no Dart name',
        );
      }
      path = c.path;
      where = 'the field "${f.name}" of "${schema.fullName}"';
      docWhere = 'the field `${f.name}` of [${c.name}]';
      final sealedName = '${c.name}$place';
      fields.add(
        _Field(
          f,
          name,
          isNull ? null : typeOf(f.schema, sealedName),
          sealedName,
        ),
      );
    }
    final dart = [
      for (final f in fields)
        if (f.type != null) f,
    ];
    final n = c.name;
    final b = body;
    _doc(b, schema.doc, '');
    b.writeln('final class $n {');
    // The constructor.
    if (dart.isEmpty) {
      b.writeln('  const $n();');
    } else {
      b.writeln('  const $n({');
      for (final f in dart) {
        b.writeln(
          f.nullable ? '    this.${f.name},' : '    required this.${f.name},',
        );
      }
      b.writeln('  });');
    }
    // The fields.
    for (final f in dart) {
      b.writeln();
      _doc(b, f.avro.doc, '  ');
      b.writeln('  final ${f.type} ${f.name};');
    }
    // The descriptor.
    b
      ..writeln()
      ..writeln(
        '  /// The schema of [$n] and the conversion from and to the generic values of '
        'AvroCodec.',
      )
      ..writeln('  static final AvroType<$n> avroType = AvroType<$n>(')
      ..writeln('    schemaJson: ${_multiline(c.schemaJson)},')
      ..writeln('    toAvro: (value) => <String, Object?>{');
    for (final f in fields) {
      final value = f.type == null
          ? 'null'
          : toAvro(f.avro.schema, 'value.${f.name}', 0, f.place) ??
                'value.${f.name}';
      b.writeln("      '${f.avro.name}': $value,");
    }
    b.writeln('    },');
    if (dart.isEmpty) {
      b.writeln('    fromAvro: (value) => const $n(),');
    } else {
      b
        ..writeln('    fromAvro: (value) {')
        ..writeln('      final m = value as Map<String, Object?>;')
        ..writeln('      return $n(');
      for (final f in dart) {
        b.writeln(
          '        ${f.name}: ${fromAvro(f.avro.schema, "m['${f.avro.name}']", 0, f.place)},',
        );
      }
      b
        ..writeln('      );')
        ..writeln('    },');
    }
    b.writeln('  );');
    // copyWith.
    b
      ..writeln()
      ..writeln(
        '  /// A copy with the given fields replaced. A null argument keeps the field,',
      )
      ..writeln('  /// so `copyWith` cannot set a nullable field to null.');
    if (dart.isEmpty) {
      b.writeln('  $n copyWith() => this;');
    } else {
      b.writeln('  $n copyWith({');
      for (final f in dart) {
        b.writeln('    ${f.nullable ? f.type : '${f.type}?'} ${f.name},');
      }
      b.writeln('  }) => $n(');
      for (final f in dart) {
        b.writeln('    ${f.name}: ${f.name} ?? this.${f.name},');
      }
      b.writeln('  );');
    }
    // ==, hashCode and toString.
    usesDeep = usesDeep || dart.any((f) => f.deep);
    b
      ..writeln()
      ..writeln('  @override')
      ..write('  bool operator ==(Object other) => other is $n');
    for (final f in dart) {
      b.write(
        f.deep
            ? ' && _deepEquals(other.${f.name}, ${f.name})'
            : ' && other.${f.name} == ${f.name}',
      );
    }
    b
      ..writeln(';')
      ..writeln()
      ..writeln('  @override');
    final hashes = [
      for (final f in dart) f.deep ? '_deepHash(${f.name})' : f.name,
    ];
    b.writeln(switch (hashes.length) {
      0 => '  int get hashCode => 0;',
      1 =>
        dart.single.deep
            ? '  int get hashCode => ${hashes.single};'
            : '  int get hashCode => ${hashes.single}.hashCode;',
      <= 20 => '  int get hashCode => Object.hash(${hashes.join(', ')});',
      _ => '  int get hashCode => Object.hashAll([${hashes.join(', ')}]);',
    });
    final shown = [
      for (final f in dart)
        f.name.contains(r'$')
            ? '${f.name.replaceAll(r'$', r'\$')}: \${${f.name}}'
            : '${f.name}: \$${f.name}',
    ];
    b
      ..writeln()
      ..writeln('  @override')
      ..writeln("  String toString() => '$n(${shown.join(', ')})';")
      ..writeln('}')
      ..writeln();
    pending.forEach(writeSealed);
    pending.clear();
  }

  void writeSealed(_Sealed u) {
    final n = u.name;
    body
      ..writeln('/// A value of the union in ${u.doc}: one class per branch.')
      ..writeln('sealed class $n {')
      ..writeln('  const $n();')
      ..writeln('}')
      ..writeln();
    for (final b in u.branches) {
      final deep =
          b.type.startsWith('List<') ||
          b.type.startsWith('Map<') ||
          b.type.startsWith('Uint8List');
      usesDeep = usesDeep || deep;
      body
        ..writeln('/// The branch `${branchName(b.schema)}` of [$n].')
        ..writeln('final class ${b.name} extends $n {')
        ..writeln('  const ${b.name}(this.value);')
        ..writeln()
        ..writeln('  final ${b.type} value;')
        ..writeln()
        ..writeln('  @override')
        ..writeln(
          deep
              ? '  bool operator ==(Object other) => '
                    'other is ${b.name} && _deepEquals(other.value, value);'
              : '  bool operator ==(Object other) => '
                    'other is ${b.name} && other.value == value;',
        )
        ..writeln()
        ..writeln('  @override')
        ..writeln(
          deep
              ? '  int get hashCode => _deepHash(value);'
              : '  int get hashCode => value.hashCode;',
        )
        ..writeln()
        ..writeln('  @override')
        ..writeln("  String toString() => '${b.name}(\$value)';")
        ..writeln('}')
        ..writeln();
    }
  }
}

/// Whether [u] has two or more non-null branches, which give a sealed class.
bool _isWide(UnionSchema u) =>
    u.branches.where((b) => b.type != 'null').length > 1;

/// The non-null branch of a union of `null` and one other type, or null for any other union.
Schema? _nullableBranch(UnionSchema u) {
  if (u.branches.length != 2) return null;
  final [a, b] = u.branches;
  if (a is PrimitiveSchema && a.type == 'null') return b;
  if (b is PrimitiveSchema && b.type == 'null') return a;
  return null;
}

/// Writes [doc] as a doc comment, with angle brackets outside code spans escaped so that
/// they are not read as HTML.
void _doc(StringBuffer out, String? doc, String indent) {
  if (doc == null || doc.trim().isEmpty) return;
  var inCode = false;
  for (final line in const LineSplitter().convert(doc.trim())) {
    final escaped = StringBuffer();
    for (final c in line.split('')) {
      if (c == '`') inCode = !inCode;
      escaped.write(!inCode && (c == '<' || c == '>') ? '\\$c' : c);
    }
    final text = escaped.toString().trimRight();
    out.writeln(text.isEmpty ? '$indent///' : '$indent/// $text');
  }
}

/// [text] as a Dart multi-line string literal that gives exactly [text].
String _multiline(String text) {
  final out = StringBuffer("'''");
  // A first line of only blanks would be dropped by Dart; escape its line break.
  final firstBreak = text.indexOf('\n');
  final blankFirstLine =
      firstBreak >= 0 && text.substring(0, firstBreak).trim().isEmpty;
  var quotes = 0; // the quotes in a row so far
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    final unit = c.codeUnitAt(0);
    if (c == "'") {
      quotes++;
      // Escape every third quote in a row and a quote at the very end, so that no `'''` ends
      // the literal early.
      out.write(quotes % 3 == 0 || i == text.length - 1 ? r"\'" : "'");
      continue;
    }
    quotes = 0;
    if (c == r'\') {
      out.write(r'\\');
    } else if (c == r'$') {
      out.write(r'\$');
    } else if (c == '\r') {
      out.write(r'\r');
    } else if (c == '\n') {
      out.write(blankFirstLine && i == firstBreak ? r'\n' : '\n');
    } else if (c == ' ' && blankFirstLine && i < firstBreak) {
      out.write(r'\x20');
    } else if (c == '\t' && blankFirstLine && i < firstBreak) {
      out.write(r'\t');
    } else if (unit < 0x20 && c != '\t') {
      out.write('\\x${unit.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.write(c);
    }
  }
  out.write("'''");
  return out.toString();
}

const _deepHelpers = r'''
/// Whether [a] and [b] are equal, comparing lists and maps by their elements.
bool _deepEquals(Object? a, Object? b) {
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || !_deepEquals(e.value, b[e.key])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

/// The hash code of [value] that fits [_deepEquals].
int _deepHash(Object? value) => switch (value) {
  final List<Object?> list => Object.hashAll(list.map(_deepHash)),
  final Map<Object?, Object?> map => Object.hashAllUnordered(
    map.entries.map((e) => Object.hash(e.key, _deepHash(e.value))),
  ),
  _ => value.hashCode,
};
''';
