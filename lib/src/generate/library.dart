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

/// The Dart library of the classes of every record in [files]. Throws [GenerateException]
/// if a file is not a valid schema or a name cannot be generated.
String generateLibrary(List<SchemaFile> files) {
  final classes = <_Class>[];
  final definedIn = <String, String>{};
  final classOf = <RecordSchema, _Class>{};
  final classNames = <String, NamedSchema>{};
  for (final file in files) {
    final Schema root;
    try {
      root = Schema.parse(file.text, limits: AvroLimits.none);
    } on SchemaParseException catch (e) {
      throw GenerateException('${file.path}: $e');
    }
    for (final named in _namedTypes(root)) {
      final earlier = definedIn[named.fullName];
      if (earlier != null) {
        throw GenerateException(
          '${file.path}: "${named.fullName}" is already defined in $earlier',
        );
      }
      definedIn[named.fullName] = file.path;
      if (named is! RecordSchema) continue;
      final name = className(named.name);
      if (name == null) {
        throw GenerateException(
          '${file.path}: the record "${named.fullName}" has no Dart class name',
        );
      }
      if (clashingTypeNames.contains(name)) {
        throw GenerateException(
          '${file.path}: the class $name of "${named.fullName}" would clash with $name '
          'of dart:core, dart:typed_data or package:avro; a namespace prefix will make '
          'it possible',
        );
      }
      final other = classNames[name];
      if (other != null) {
        throw GenerateException(
          '${file.path}: "${named.fullName}" and "${other.fullName}" '
          '(${definedIn[other.fullName]}) both give the class $name',
        );
      }
      classNames[name] = named;
      final c = _Class(
        named,
        name,
        identical(named, root) ? file.text : _selfContained(named, file.path),
        file.path,
      );
      classes.add(c);
      classOf[named] = c;
    }
  }
  final out = _Library(classOf);
  for (final c in classes) {
    out.writeClass(c);
  }
  return out.finish(files);
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

  final RecordSchema schema;
  final String name;
  final String schemaJson;
  final String path;
}

/// A field of a generated class.
final class _Field {
  _Field(this.avro, this.name, this.type);

  final Field avro;
  final String name;

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

final class _Library {
  _Library(this.classOf);

  final Map<RecordSchema, _Class> classOf;
  final StringBuffer body = StringBuffer();
  bool usesTypedData = false;
  bool usesDeep = false;

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

  String typeOf(Schema s) {
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
        return 'String';
      case ArraySchema(:final items):
        return 'List<${typeOf(items)}>';
      case MapSchema(:final values):
        return 'Map<String, ${typeOf(values)}>';
      case RecordSchema():
        return classOf[s]!.name;
      case UnionSchema():
        final inner = _nullableBranch(s);
        return inner == null ? 'Object?' : '${typeOf(inner)}?';
    }
  }

  /// The generic value of a Dart value [e] of [s], or null if it is the Dart value itself.
  String? toAvro(Schema s, String e, int depth) {
    if (logicalOf(s) != null) return null;
    switch (s) {
      case RecordSchema():
        return '${classOf[s]!.name}.avroType.toAvro($e)';
      case ArraySchema(:final items):
        final x = 'x$depth';
        final inner = toAvro(items, x, depth + 1);
        return inner == null ? null : '[for (final $x in $e) $inner]';
      case MapSchema(:final values):
        final x = 'x$depth';
        final inner = toAvro(values, '$x.value', depth + 1);
        return inner == null
            ? null
            : '{for (final $x in $e.entries) $x.key: $inner}';
      case UnionSchema():
        final branch = _nullableBranch(s);
        if (branch == null) return null;
        final v = 'v$depth';
        final inner = toAvro(branch, v, depth + 1);
        return inner == null
            ? null
            : 'switch ($e) { final $v? => $inner, null => null }';
      case PrimitiveSchema() || EnumSchema() || FixedSchema():
        return null;
    }
  }

  /// The Dart value of [s] for a generic value [e].
  String fromAvro(Schema s, String e, int depth) {
    if (logicalOf(s) != null) return '$e as ${typeOf(s)}';
    switch (s) {
      case RecordSchema():
        return '${classOf[s]!.name}.avroType.fromAvro($e)';
      case ArraySchema(:final items):
        final x = 'x$depth';
        return '[for (final $x in $e as List<Object?>) '
            '${fromAvro(items, x, depth + 1)}]';
      case MapSchema(:final values):
        final x = 'x$depth';
        return '{for (final $x in ($e as Map<String, Object?>).entries) '
            '$x.key: ${fromAvro(values, '$x.value', depth + 1)}}';
      case UnionSchema():
        final branch = _nullableBranch(s);
        if (branch == null) return e;
        final type = typeOf(branch);
        if (_isCast(branch)) return '$e as $type?';
        final v = 'v$depth';
        return 'switch ($e) { final $v? => ${fromAvro(branch, v, depth + 1)}, '
            'null => null }';
      case PrimitiveSchema() || EnumSchema() || FixedSchema():
        return '$e as ${typeOf(s)}';
    }
  }

  /// Whether [fromAvro] of [s] is a cast.
  bool _isCast(Schema s) =>
      logicalOf(s) != null ||
      s is PrimitiveSchema ||
      s is EnumSchema ||
      s is FixedSchema;

  void writeClass(_Class c) {
    final schema = c.schema;
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
      fields.add(_Field(f, name, isNull ? null : typeOf(f.schema)));
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
          : toAvro(f.avro.schema, 'value.${f.name}', 0) ?? 'value.${f.name}';
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
          '        ${f.name}: ${fromAvro(f.avro.schema, "m['${f.avro.name}']", 0)},',
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
  }
}

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
