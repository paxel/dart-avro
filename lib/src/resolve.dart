import 'dart:convert';
import 'dart:typed_data';

import 'binary.dart';
import 'codec.dart' show Branch;
import 'exceptions.dart';
import 'logical.dart';
import 'schema.dart';

/// Reads data of a writer schema into the shape of a reader schema. Compiled once from the
/// two schemas by [resolve].
sealed class Plan {
  const Plan();
}

/// The writer's schema read as it is; the reader's logical type, if any, applies.
final class _Direct extends Plan {
  const _Direct(this.writer, this.reader);

  final Schema writer;
  final Schema reader;
}

/// A primitive promoted to the reader's type.
final class _Promote extends Plan {
  const _Promote(this.from, this.reader);

  final String from;
  final Schema reader;
}

final class _Record extends Plan {
  _Record(this.reader);

  final RecordSchema reader;

  /// One step per writer field, in the writer's order: the reader field it fills and how,
  /// or null with the writer's schema to skip.
  late final List<(String?, Plan?, Schema)> steps;

  /// The reader fields the writer lacks, with their defaults.
  late final List<(String, Object?)> defaults;
}

final class _Enum extends Plan {
  const _Enum(this.writer, this.reader, this.symbols);

  final EnumSchema writer;
  final EnumSchema reader;

  /// The reader's symbol for each writer index; null where the writer's symbol has none.
  final List<String?> symbols;
}

final class _Array extends Plan {
  const _Array(this.writerItems, this.items, this.reader);

  final Schema writerItems;
  final Plan items;
  final Schema reader;
}

final class _Map extends Plan {
  const _Map(this.writerValues, this.values, this.reader);

  final Schema writerValues;
  final Plan values;
  final Schema reader;
}

/// A writer union: one plan per writer branch, or the reason the branch does not resolve.
final class _WriterUnion extends Plan {
  const _WriterUnion(this.branches);

  final List<Object> branches;
}

/// The writer's schema read as one branch of the reader's union.
final class _ReaderBranch extends Plan {
  const _ReaderBranch(this.plan, this.name);

  final Plan plan;

  /// The name of the [Branch] the value is decoded into; null to decode it plain.
  final String? name;
}

/// Compiles the plan that reads data of [writer] as [reader]. Throws [ResolutionException]
/// if the schemas do not resolve. With [branches], values of the reader's unions with two or
/// more non-null branches, defaults included, are read as a [Branch] of the reader's branch.
Plan resolve(Schema writer, Schema reader, {bool branches = false}) =>
    _Resolver(branches).plan(writer, reader, branchName(reader));

bool _namesMatch(NamedSchema w, NamedSchema r) =>
    w.name == r.name ||
    r.aliases.contains(w.fullName) ||
    r.aliases.any((a) => a.split('.').last == w.name);

const _promotions = {
  'int': {'long', 'float', 'double'},
  'long': {'float', 'double'},
  'float': {'double'},
  'string': {'bytes'},
  'bytes': {'string'},
};

final class _Resolver {
  _Resolver(this.decodeBranches);

  /// Whether unions are read as a [Branch]; see [resolve].
  final bool decodeBranches;

  final Map<(RecordSchema, RecordSchema), _Record> records = {};

  Never fail(String message, String path) =>
      throw ResolutionException(message, path: path);

  /// Whether the two schemas match at their top, as the specification defines it.
  bool matches(Schema w, Schema r) => switch ((w, r)) {
    (UnionSchema(), _) || (_, UnionSchema()) => true,
    (ArraySchema(), ArraySchema()) || (MapSchema(), MapSchema()) => true,
    (final EnumSchema w, final EnumSchema r) => _namesMatch(w, r),
    (final FixedSchema w, final FixedSchema r) =>
      w.size == r.size && _namesMatch(w, r),
    (final RecordSchema w, final RecordSchema r) => _namesMatch(w, r),
    (PrimitiveSchema(type: final a), PrimitiveSchema(type: final b)) =>
      a == b || (_promotions[a]?.contains(b) ?? false),
    _ => false,
  };

  Plan plan(Schema w, Schema r, String path) {
    if (identical(w, r)) return _Direct(w, r);
    if (w is UnionSchema) {
      final branches = <Object>[
        for (final b in w.branches)
          _orReason(() => plan(b, r, '$path<${branchName(b)}>')),
      ];
      if (branches.every((b) => b is String)) {
        fail(
          'no branch of the writer union ${w.branches.map(branchName).join(', ')} '
          'resolves against ${branchName(r)}',
          path,
        );
      }
      return _WriterUnion(branches);
    }
    if (r is UnionSchema) {
      final i = readerBranch(w, r, path);
      if (i >= 0) {
        final b = r.branches[i];
        return _ReaderBranch(
          plan(w, b, path),
          decodeBranches && decodesAsBranch(r, b) ? branchName(b) : null,
        );
      }
      fail(
        'no branch of the reader union ${r.branches.map(branchName).join(', ')} '
        'matches ${branchName(w)}',
        path,
      );
    }
    if (!matches(w, r)) {
      fail('${branchName(w)} does not resolve to ${branchName(r)}', path);
    }
    _checkDecimal(w, r, path);
    switch ((w, r)) {
      case (PrimitiveSchema(type: final a), PrimitiveSchema(type: final b)):
        return a == b ? _Direct(w, r) : _Promote(a, r);
      case (FixedSchema(), FixedSchema()):
        return _Direct(w, r);
      case (final ArraySchema w, final ArraySchema r):
        return _Array(w.items, plan(w.items, r.items, '$path[]'), r);
      case (final MapSchema w, final MapSchema r):
        return _Map(w.values, plan(w.values, r.values, '$path{}'), r);
      case (final EnumSchema w, final EnumSchema r):
        return _Enum(w, r, [
          for (final s in w.symbols)
            r.symbols.contains(s) ? s : r.defaultSymbol,
        ]);
      case (final RecordSchema w, final RecordSchema r):
        return record(w, r, path);
      default:
        fail('${branchName(w)} does not resolve to ${branchName(r)}', path);
    }
  }

  /// The reader branch that takes [w], in the order of Apache Avro's Java implementation
  /// (`Resolver.firstMatchingBranch`): the same type, or the same full name for a named type;
  /// then the first record that resolves, preferring the same short name; then a promotion;
  /// then any other match, such as a name found by alias. -1 if none matches.
  int readerBranch(Schema w, UnionSchema r, String path) {
    final branches = r.branches;
    var structure = -1;
    for (var i = 0; i < branches.length; i++) {
      final b = branches[i];
      if (b.type != w.type) continue;
      if (w is NamedSchema && b is NamedSchema) {
        if (w.fullName == b.fullName) return i;
        if (w is RecordSchema && b is RecordSchema && _resolves(w, b, path)) {
          if (structure < 0 || w.name == b.name) structure = i;
        }
      } else if (w is! NamedSchema) {
        return i;
      }
    }
    if (structure >= 0) return structure;
    final promoted = _promotions[w.type];
    if (promoted != null) {
      for (var i = 0; i < branches.length; i++) {
        if (promoted.contains(branches[i].type)) return i;
      }
    }
    for (var i = 0; i < branches.length; i++) {
      if (matches(w, branches[i])) return i;
    }
    return -1;
  }

  bool _resolves(Schema w, Schema r, String path) {
    try {
      plan(w, r, path);
      return true;
    } on ResolutionException {
      return false;
    }
  }

  Object _orReason(Plan Function() f) {
    try {
      return f();
    } on ResolutionException catch (e) {
      return e.toString();
    }
  }

  void _checkDecimal(Schema w, Schema r, String path) {
    if (logicalOf(w) == Logical.decimal && logicalOf(r) == Logical.decimal) {
      if (decimalParameters(w) != decimalParameters(r)) {
        fail('the decimals differ in precision or scale', path);
      }
    }
  }

  _Record record(RecordSchema w, RecordSchema r, String path) {
    final known = records[(w, r)];
    if (known != null) return known;
    final node = _Record(r);
    records[(w, r)] = node;
    try {
      return _fillRecord(node, w, r, path);
    } on ResolutionException {
      // A failed attempt, such as trying a union branch, must not leave a half-built node.
      records.remove((w, r));
      rethrow;
    }
  }

  _Record _fillRecord(
    _Record node,
    RecordSchema w,
    RecordSchema r,
    String path,
  ) {
    final used = <String>{};
    final steps = <(String?, Plan?, Schema)>[];
    for (final wf in w.fields) {
      Field? match;
      for (final rf in r.fields) {
        if (rf.name == wf.name) match = rf;
      }
      match ??= r.fields
          .where((rf) => rf.aliases.contains(wf.name))
          .firstOrNull;
      if (match == null || used.contains(match.name)) {
        steps.add((null, null, wf.schema));
      } else {
        used.add(match.name);
        steps.add((
          match.name,
          plan(wf.schema, match.schema, '$path.${match.name}'),
          wf.schema,
        ));
      }
    }
    final defaults = <(String, Object?)>[];
    for (final rf in r.fields) {
      if (used.contains(rf.name)) continue;
      if (!rf.hasDefault) {
        fail(
          'the reader field "${rf.name}" has no default and the writer lacks it',
          '$path.${rf.name}',
        );
      }
      defaults.add((
        rf.name,
        decodeBranches
            ? defaultValueOf(rf.schema, rf.json['default'], branches: true)
            : rf.defaultValue,
      ));
    }
    node.steps = steps;
    node.defaults = defaults;
    return node;
  }
}

/// A deep copy of a default, so that callers cannot change the default by changing a value.
Object? copyDefault(Object? v) => switch (v) {
  final Uint8List b => Uint8List.fromList(b),
  final List<Object?> l => [for (final e in l) copyDefault(e)],
  final Map<String, Object?> m => {
    for (final e in m.entries) e.key: copyDefault(e.value),
  },
  Branch(:final name, :final value) => Branch(name, copyDefault(value)),
  _ => v,
};

/// Runs [plan] with the decoder's primitives.
Object? runPlan(
  Plan plan,
  BinaryReader input,
  Object? Function(Schema schema, String path, int depth) decodeWriter,
  int Function(Schema items, int extra, String path) blockCount,
  void Function(String path, int depth) checkDepth,
  String path,
  int depth,
) {
  Object? run(Plan p, String path, int depth) {
    checkDepth(path, depth);
    Object? logicalOfReader(Schema reader, Object? raw, int start) {
      final l = logicalOf(reader);
      if (l == null) return raw;
      return fromUnderlying(
        l,
        reader,
        raw,
        (m) => throw DecodeException(m, offset: start, path: path),
      );
    }

    switch (p) {
      case _Direct(:final writer, :final reader):
        if (identical(writer, reader)) return decodeWriter(writer, path, depth);
        final start = input.offset;
        final raw = logicalOf(writer) == null
            ? decodeWriter(writer, path, depth)
            : decodeWriter(_underlying(writer), path, depth);
        return logicalOfReader(reader, raw, start);
      case _Promote(:final from, :final reader):
        final start = input.offset;
        final Object raw = switch ((from, reader.type)) {
          ('int', 'long') => input.readInt(),
          ('int', _) => input.readInt().toDouble(),
          ('long', _) => input.readLong().toDouble(),
          ('float', _) => input.readFloat(),
          ('string', _) => input.readBytes(),
          ('bytes', _) => input.readString(),
          _ => throw StateError('no promotion from $from'),
        };
        return logicalOfReader(reader, raw, start);
      case _Enum(:final writer, :final reader, :final symbols):
        final start = input.offset;
        final i = input.readInt();
        if (i < 0 || i >= symbols.length) {
          input.fail('$i is not a symbol of ${writer.fullName}', start);
        }
        return symbols[i] ??
            (throw ResolutionException(
              'the writer symbol "${writer.symbols[i]}" is not in ${reader.fullName}, '
              'which has no default',
              path: path,
            ));
      case _Array(:final writerItems, :final items, :final reader):
        final start = input.offset;
        final out = <Object?>[];
        while (true) {
          final count = blockCount(writerItems, 0, path);
          if (count == 0) break;
          for (var i = 0; i < count; i++) {
            out.add(run(items, '$path[${out.length}]', depth + 1));
          }
        }
        return logicalOfReader(reader, out, start);
      case _Map(:final writerValues, :final values, :final reader):
        final start = input.offset;
        final out = <String, Object?>{};
        while (true) {
          final count = blockCount(writerValues, 1, path);
          if (count == 0) break;
          for (var i = 0; i < count; i++) {
            final key = input.readString();
            out[key] = run(values, '$path.$key', depth + 1);
          }
        }
        return logicalOfReader(reader, out, start);
      case _Record(:final reader):
        final values = <String, Object?>{};
        for (final (name, step, writerSchema) in p.steps) {
          if (name == null) {
            decodeWriter(writerSchema, path, depth + 1);
          } else {
            values[name] = run(step!, '$path.$name', depth + 1);
          }
        }
        for (final (name, value) in p.defaults) {
          values[name] = copyDefault(value);
        }
        return {for (final f in reader.fields) f.name: values[f.name]};
      case _WriterUnion(:final branches):
        final start = input.offset;
        final i = input.readInt();
        if (i < 0 || i >= branches.length) {
          input.fail('the union has no branch $i', start);
        }
        return switch (branches[i]) {
          final Plan plan => run(plan, path, depth + 1),
          final reason => throw ResolutionException(
            'the writer wrote a branch that does not resolve: $reason',
            path: path,
          ),
        };
      case _ReaderBranch(:final plan, :final name):
        final value = run(plan, path, depth);
        return name == null ? value : Branch(name, value);
    }
  }

  return run(plan, path, depth);
}

final _underlyingSchemas = Expando<Schema>();

/// [s] without its logical type, so that its value is read as the underlying type.
Schema _underlying(Schema s) => _underlyingSchemas[s] ??= _strip(s);

Schema _strip(Schema s) {
  final json = Map<String, Object?>.of(s.json! as Map<String, Object?>)
    ..remove('logicalType');
  return Schema.parse(jsonEncode(json));
}
