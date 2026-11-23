@Tags(['web'])
library;

import 'dart:convert';
import 'dart:math';

import 'package:avro/avro.dart';
import 'package:test/test.dart';

Schema s(String json) => Schema.parse(json);

SchemaCompatibility check(String writer, String reader) =>
    checkCompatibility(reader: s(reader), writer: s(writer));

bool codecBuilds(Schema writer, Schema reader) {
  try {
    AvroCodec(writer: writer, reader: reader);
    return true;
  } on ResolutionException {
    return false;
  }
}

const _memo =
    '{"type": "record", "name": "Memo", "fields": ['
    '{"name": "id", "type": "int"}, {"name": "text", "type": "string"}]}';

/// Schemas to check against each other: every pair of them is a case.
const _pool = [
  '"null"',
  '"boolean"',
  '"int"',
  '"long"',
  '"float"',
  '"double"',
  '"bytes"',
  '"string"',
  '{"type": "fixed", "name": "F", "size": 4}',
  '{"type": "fixed", "name": "F", "size": 8}',
  '{"type": "fixed", "name": "G", "size": 4, "aliases": ["F"]}',
  '{"type": "fixed", "name": "D", "size": 4, "logicalType": "decimal", "precision": 5, "scale": 2}',
  '{"type": "fixed", "name": "D", "size": 4, "logicalType": "decimal", "precision": 5, "scale": 1}',
  '{"type": "bytes", "logicalType": "decimal", "precision": 5, "scale": 2}',
  '{"type": "enum", "name": "E", "symbols": ["a", "b"]}',
  '{"type": "enum", "name": "E", "symbols": ["a", "b", "c"]}',
  '{"type": "enum", "name": "E", "symbols": ["a"], "default": "a"}',
  '{"type": "enum", "name": "X", "symbols": ["a", "b"]}',
  '{"type": "array", "items": "int"}',
  '{"type": "array", "items": "long"}',
  '{"type": "array", "items": "string"}',
  '{"type": "map", "values": "int"}',
  '{"type": "map", "values": ["null", "string"]}',
  '["null", "int"]',
  '["null", "string"]',
  '["int", "string"]',
  '["null", "long", "string"]',
  '["null", {"type": "array", "items": "int"}]',
  _memo,
  '{"type": "record", "name": "Memo", "fields": ['
      '{"name": "id", "type": "long"}, {"name": "text", "type": "string"}, '
      '{"name": "tags", "type": {"type": "array", "items": "string"}, "default": []}]}',
  '{"type": "record", "name": "Memo", "fields": ['
      '{"name": "id", "type": "int"}, {"name": "body", "type": "string", "aliases": ["text"]}]}',
  '{"type": "record", "name": "Memo", "fields": ['
      '{"name": "id", "type": "int"}, {"name": "due", "type": "long"}]}',
  '{"type": "record", "name": "Note", "aliases": ["Memo"], "fields": ['
      '{"name": "id", "type": "int"}]}',
  '{"type": "record", "name": "Other", "fields": [{"name": "id", "type": "int"}]}',
  '{"type": "record", "name": "Memo", "fields": ['
      '{"name": "id", "type": {"type": "enum", "name": "K", "symbols": ["x"]}}]}',
  '{"type": "record", "name": "L", "fields": [{"name": "v", "type": "int"}, '
      '{"name": "next", "type": ["null", "L"]}]}',
  '{"type": "record", "name": "L", "fields": [{"name": "v", "type": "long"}, '
      '{"name": "next", "type": ["null", "L"]}]}',
  '{"type": "record", "name": "L", "fields": [{"name": "v", "type": "string"}, '
      '{"name": "next", "type": ["null", "L"]}]}',
  '["null", $_memo]',
  '["null", {"type": "record", "name": "Other", "fields": [{"name": "id", "type": "int"}]}, '
      '$_memo]',
  // Namespaces and aliases, as in resolve_test.dart.
  '{"type": "record", "name": "a.R", "fields": [{"name": "x", "type": "int"}]}',
  '{"type": "record", "name": "b.R", "aliases": ["a.R"], "fields": ['
      '{"name": "x", "type": "long"}]}',
  '{"type": "record", "name": "c.Q", "aliases": ["R"], "fields": ['
      '{"name": "x", "type": "int"}]}',
  '[{"type": "record", "name": "b.R", "fields": [{"name": "y", "type": "int"}]}, '
      '{"type": "record", "name": "c.R", "fields": [{"name": "x", "type": "long"}]}]',
  '[{"type": "record", "name": "b.R", "fields": [{"name": "y", "type": "int"}]}, '
      '{"type": "record", "name": "c.R", "fields": [{"name": "x", "type": "long"}]}, '
      '{"type": "record", "name": "a.R", "fields": [{"name": "x", "type": "int"}, '
      '{"name": "z", "type": "int", "default": 9}]}]',
  '{"type": "record", "name": "Memo", "namespace": "b", "fields": ['
      '{"name": "count", "type": "long"}, '
      '{"name": "added", "type": "string", "default": "new"}, '
      '{"name": "text", "type": "string"}]}',
  '{"type": "record", "name": "Memo", "namespace": "a", "fields": ['
      '{"name": "text", "type": "string"}, '
      '{"name": "gone", "type": {"type": "array", "items": "long"}}, '
      '{"name": "count", "type": "int"}]}',
];

void main() {
  group('compatible', () {
    test('identical, promoted and evolved schemas', () {
      expect(check('"int"', '"int"').isCompatible, isTrue);
      expect(check('"int"', '"double"').isCompatible, isTrue);
      expect(check('"string"', '"bytes"').isCompatible, isTrue);
      expect(check(_memo, _pool[29]).isCompatible, isTrue);
      expect(check(_memo, _pool[30]).isCompatible, isTrue);
      expect(check('"int"', '["null", "long"]').isCompatible, isTrue);
      final memo = s(_memo);
      expect(
        checkCompatibility(reader: memo, writer: memo).incompatibilities,
        isEmpty,
      );
    });

    test('a named type found by an alias', () {
      expect(check(_pool[8], _pool[10]).isCompatible, isTrue);
      expect(check(_memo, _pool[32]).isCompatible, isTrue);
    });
  });

  group('every kind', () {
    void expectOne(String writer, String reader, Incompatibility expected) {
      expect(check(writer, reader).incompatibilities, [expected]);
    }

    test('typeMismatch', () {
      expectOne(
        '"long"',
        '"int"',
        const Incompatibility(
          IncompatibilityKind.typeMismatch,
          'long does not resolve to int',
          readerPath: 'int',
          writerPath: 'long',
        ),
      );
    });

    test('nameMismatch', () {
      expectOne(
        _pool[14],
        _pool[17],
        const Incompatibility(
          IncompatibilityKind.nameMismatch,
          'the writer enum E is neither X nor one of its aliases',
          readerPath: 'X',
          writerPath: 'E',
        ),
      );
    });

    test('fixedSizeMismatch', () {
      expectOne(
        _pool[8],
        _pool[9],
        const Incompatibility(
          IncompatibilityKind.fixedSizeMismatch,
          'the writer fixed has 4 bytes, the reader fixed 8',
          readerPath: 'F',
          writerPath: 'F',
        ),
      );
    });

    test('missingEnumSymbols', () {
      expectOne(
        _pool[15],
        _pool[14],
        const Incompatibility(
          IncompatibilityKind.missingEnumSymbols,
          'the reader enum lacks the writer symbols c and has no default',
          readerPath: 'E',
          writerPath: 'E',
        ),
      );
      expect(check(_pool[15], _pool[16]).isCompatible, isTrue);
    });

    test('readerFieldMissingDefaultValue', () {
      expectOne(
        _memo,
        _pool[31],
        const Incompatibility(
          IncompatibilityKind.readerFieldMissingDefaultValue,
          'the reader field "due" has no default and the writer lacks it',
          readerPath: 'Memo.due',
          writerPath: 'Memo',
        ),
      );
    });

    test('missingUnionBranch', () {
      expectOne(
        '{"type": "array", "items": "boolean"}',
        '{"type": "array", "items": ["null", "string"]}',
        const Incompatibility(
          IncompatibilityKind.missingUnionBranch,
          'no branch of the reader union null, string matches boolean',
          readerPath: 'array[]',
          writerPath: 'array[]',
        ),
      );
    });

    test('decimalMismatch', () {
      expectOne(
        _pool[11],
        _pool[12],
        const Incompatibility(
          IncompatibilityKind.decimalMismatch,
          'the decimals differ in precision or scale',
          readerPath: 'D',
          writerPath: 'D',
        ),
      );
    });
  });

  test('every incompatibility is reported, not only the first', () {
    final result = check(
      '{"type": "record", "name": "R", "fields": ['
          '{"name": "a", "type": "long"}, '
          '{"name": "b", "type": {"type": "fixed", "name": "F", "size": 2}}, '
          '{"name": "c", "type": {"type": "map", "values": ["int", "boolean"]}}]}',
      '{"type": "record", "name": "S", "fields": ['
          '{"name": "a", "type": "int"}, '
          '{"name": "b", "type": {"type": "fixed", "name": "G", "size": 3}}, '
          '{"name": "c", "type": {"type": "map", "values": "int"}}, '
          '{"name": "d", "type": "string"}]}',
    );
    expect(result.isCompatible, isFalse);
    expect(
      [
        for (final i in result.incompatibilities)
          (i.kind, i.writerPath, i.readerPath),
      ],
      [
        (IncompatibilityKind.nameMismatch, 'R', 'S'),
        (IncompatibilityKind.typeMismatch, 'R.a', 'S.a'),
        (IncompatibilityKind.nameMismatch, 'R.b', 'S.b'),
        (IncompatibilityKind.fixedSizeMismatch, 'R.b', 'S.b'),
        (IncompatibilityKind.typeMismatch, 'R.c{}<boolean>', 'S.c{}'),
        (IncompatibilityKind.readerFieldMissingDefaultValue, 'R', 'S.d'),
      ],
    );
  });

  test('paths follow each schema: its field names and its union branches', () {
    final result = check(
      '{"type": "record", "name": "Memo", "fields": [{"name": "text", "type": "boolean"}]}',
      '{"type": "record", "name": "Memo", "fields": ['
          '{"name": "body", "type": ["null", "string"], "aliases": ["text"]}]}',
    );
    expect(result.incompatibilities.single.writerPath, 'Memo.text');
    expect(result.incompatibilities.single.readerPath, 'Memo.body');
    final branch = check(
      '["null", "boolean"]',
      '["null", {"type": "array", "items": "int"}]',
    );
    expect(
      [for (final i in branch.incompatibilities) (i.writerPath, i.readerPath)],
      [('union<boolean>', 'union')],
    );
    final chosen = check(
      '{"type": "array", "items": "long"}',
      '["null", {"type": "array", "items": "int"}]',
    );
    expect(chosen.incompatibilities.single.readerPath, 'union<array>[]');
  });

  test(
    'recursive schemas end, and an incompatibility in them is reported once',
    () {
      final result = check(_pool[37], _pool[35]);
      expect(result.incompatibilities, [
        const Incompatibility(
          IncompatibilityKind.typeMismatch,
          'string does not resolve to int',
          readerPath: 'L.v',
          writerPath: 'L.v',
        ),
      ]);
      expect(check(_pool[35], _pool[36]).isCompatible, isTrue);
    },
  );

  group('where only some data fails, the codec still builds', () {
    test('a writer enum symbol the reader lacks, without a default', () {
      expect(codecBuilds(s(_pool[15]), s(_pool[14])), isTrue);
      expect(check(_pool[15], _pool[14]).isCompatible, isFalse);
    });

    test('a branch of a writer union that does not resolve', () {
      expect(codecBuilds(s('["null", "int"]'), s('"long"')), isTrue);
      expect(check('["null", "int"]', '"long"').incompatibilities, [
        const Incompatibility(
          IncompatibilityKind.typeMismatch,
          'null does not resolve to long',
          readerPath: 'long',
          writerPath: 'union<null>',
        ),
      ]);
    });
  });

  test('the check agrees with the resolver on every pair of the pool', () {
    expect(agree([for (final json in _pool) s(json)]), greaterThan(0));
  });

  test('the check agrees with the resolver on pairs of generated schemas', () {
    final random = Random(20261122);
    var dataDependent = 0;
    for (var round = 0; round < 50; round++) {
      dataDependent += agree([
        for (var i = 0; i < 12; i++)
          s(jsonEncode(generateSchema(random, 0, <String>{}))),
      ]);
    }
    expect(dataDependent, greaterThan(0));
  });
}

/// Checks every pair of [schemas] with [checkCompatibility] against building an
/// `AvroCodec`; returns the number of pairs that only some data fails.
int agree(List<Schema> schemas) {
  var dataDependent = 0;
  for (final w in schemas) {
    for (final r in schemas) {
      final result = checkCompatibility(reader: r, writer: w);
      final builds = codecBuilds(w, r);
      final reason = '${w.json} read as ${r.json}: $result';
      if (!builds) expect(result.isCompatible, isFalse, reason: reason);
      if (result.isCompatible) expect(builds, isTrue, reason: reason);
      if (builds && !result.isCompatible) {
        dataDependent++;
        for (final i in result.incompatibilities) {
          expect(
            i.kind == IncompatibilityKind.missingEnumSymbols ||
                i.writerPath.contains('<'),
            isTrue,
            reason: reason,
          );
        }
      }
    }
  }
  return dataDependent;
}

const _primitives = [
  'null',
  'boolean',
  'int',
  'long',
  'float',
  'double',
  'bytes',
  'string',
];

/// A random schema of few kinds and names, so that pairs often nearly match; [names] holds
/// the named types already in it, each defined once.
Object generateSchema(Random r, int depth, Set<String> names) {
  final kind = r.nextInt(depth > 2 ? 3 : 10);
  if (kind < 3) return _primitives[r.nextInt(_primitives.length)];
  switch (kind) {
    case 3:
      if (!names.add('E')) return 'int';
      return {
        'type': 'enum',
        'name': 'E',
        'symbols': [
          for (final x in ['a', 'b', 'c'])
            if (r.nextInt(3) > 0) x,
          'z',
        ],
        if (r.nextBool()) 'default': 'z',
      };
    case 4:
      if (!names.add('F')) return 'long';
      return {'type': 'fixed', 'name': 'F', 'size': 1 + r.nextInt(2)};
    case 5:
      return {'type': 'array', 'items': generateSchema(r, depth + 1, names)};
    case 6:
      return {'type': 'map', 'values': generateSchema(r, depth + 1, names)};
    case 7:
      final branches = <Object>[];
      final kinds = <String>{};
      for (var i = 1 + r.nextInt(3); i > 0; i--) {
        final b = generateSchema(r, depth + 1, names);
        final key = switch (b) {
          final String type => type,
          {'name': final String name} => name,
          {'type': final String type} => type,
          _ => 'union',
        };
        if (key != 'union' && kinds.add(key)) branches.add(b);
      }
      return branches;
    default:
      final name = r.nextBool() ? 'R' : 'S';
      if (!names.add(name)) return 'string';
      return {
        'type': 'record',
        'name': name,
        if (r.nextInt(4) == 0) 'aliases': [name == 'R' ? 'S' : 'R'],
        'fields': [
          for (final f in ['a', 'b', 'c'])
            if (r.nextInt(3) > 0)
              r.nextInt(4) == 0
                  ? {'name': f, 'type': 'int', 'default': 0}
                  : {'name': f, 'type': generateSchema(r, depth + 1, names)},
        ],
      };
  }
}
