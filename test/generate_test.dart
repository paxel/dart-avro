import 'dart:io';

import 'package:avro/src/generate/command.dart';
import 'package:test/test.dart';

/// Inside the package, so that the generated code and the program resolve `package:avro`.
final _dir = Directory('.dart_tool/generate_test');

/// The executable of the Dart SDK: under `flutter test`, [Platform.resolvedExecutable] is the
/// Flutter tester.
final _dart =
    Platform.resolvedExecutable.split(Platform.pathSeparator).last ==
        (Platform.isWindows ? 'dart.exe' : 'dart')
    ? Platform.resolvedExecutable
    : 'dart';

const _all = r'''
{"type": "record", "name": "All", "namespace": "test.gen", "doc": "Every type, with List<int> in the doc.",
 "fields": [
  {"name": "flag", "type": "boolean", "doc": "A flag."},
  {"name": "small", "type": "int"},
  {"name": "big", "type": "long"},
  {"name": "single", "type": "float"},
  {"name": "real", "type": "double"},
  {"name": "text", "type": "string"},
  {"name": "raw", "type": "bytes"},
  {"name": "hash", "type": {"type": "fixed", "name": "Hash", "size": 4}},
  {"name": "color", "type": {"type": "enum", "name": "Color", "doc": "A colour.", "symbols": ["RED", "GREEN"]}},
  {"name": "maybe_color", "type": ["null", "Color"]},
  {"name": "colors", "type": {"type": "array", "items": "Color"}},
  {"name": "color_map", "type": {"type": "map", "values": ["null", "Color"]}},
  {"name": "odd", "type": {"type": "enum", "name": "odd_names",
    "symbols": ["class", "values", "index", "name", "symbol", "DEVICE_ADD", "HTTPCode"]}},
  {"name": "numbers", "type": {"type": "array", "items": "int"}},
  {"name": "grid", "type": {"type": "array", "items": {"type": "array", "items": "long"}}},
  {"name": "labels", "type": {"type": "map", "values": "string"}},
  {"name": "blobs", "type": {"type": "map", "values": {"type": "array", "items": "bytes"}}},
  {"name": "maybe_first", "type": ["null", "string"], "default": null},
  {"name": "maybe_last", "type": ["string", "null"], "default": "x"},
  {"name": "maybe_numbers", "type": ["null", {"type": "array", "items": ["null", "int"]}]},
  {"name": "either", "type": ["int", "long", "string"]},
  {"name": "inner", "type": {"type": "record", "name": "Inner", "doc": "An inner record.",
    "fields": [{"name": "value", "type": "int", "doc": "Its value."}]}},
  {"name": "maybe_inner", "type": ["null", "Inner"], "default": null},
  {"name": "inners", "type": {"type": "array", "items": "Inner"}},
  {"name": "inner_map", "type": {"type": "map", "values": ["null", "Inner"]}},
  {"name": "outer", "type": {"type": "record", "name": "Outer", "aliases": ["Old"], "my.prop": [1, 2],
    "fields": [
      {"name": "inner", "type": "Inner", "order": "descending"},
      {"name": "hash", "type": "Hash"},
      {"name": "plain", "type": {"type": "record", "name": "Plain", "namespace": "",
        "fields": [{"name": "at", "type": {"type": "int", "logicalType": "date"}}]}}
    ]}},
  {"name": "tree", "type": {"type": "record", "name": "Node",
    "fields": [
      {"name": "label", "type": "string"},
      {"name": "children", "type": {"type": "array", "items": "Node"}},
      {"name": "next", "type": ["Node", "null"]}
    ]}},
  {"name": "nothing", "type": "null"},
  {"name": "class", "type": "int"},
  {"name": "hashCode", "type": "int"},
  {"name": "int", "type": "int"},
  {"name": "other", "type": "int"},
  {"name": "copy_with", "type": "int"},
  {"name": "offset_seconds", "type": "int"},
  {"name": "HTTPCode", "type": "int"},
  {"name": "day", "type": {"type": "int", "logicalType": "date"}},
  {"name": "time_ms", "type": {"type": "int", "logicalType": "time-millis"}},
  {"name": "time_us", "type": {"type": "long", "logicalType": "time-micros"}},
  {"name": "stamp_ms", "type": {"type": "long", "logicalType": "timestamp-millis"}},
  {"name": "stamp_us", "type": {"type": "long", "logicalType": "timestamp-micros"}},
  {"name": "stamp_ns", "type": {"type": "long", "logicalType": "timestamp-nanos"}},
  {"name": "local_ms", "type": {"type": "long", "logicalType": "local-timestamp-millis"}},
  {"name": "local_us", "type": {"type": "long", "logicalType": "local-timestamp-micros"}},
  {"name": "local_ns", "type": {"type": "long", "logicalType": "local-timestamp-nanos"}},
  {"name": "amount", "type": {"type": "bytes", "logicalType": "decimal", "precision": 10, "scale": 2}},
  {"name": "fixed_amount", "type": {"type": "fixed", "name": "Money", "size": 8, "logicalType": "decimal", "precision": 18, "scale": 3}},
  {"name": "any_amount", "type": {"type": "bytes", "logicalType": "big-decimal"}},
  {"name": "id", "type": {"type": "string", "logicalType": "uuid"}},
  {"name": "fixed_id", "type": {"type": "fixed", "name": "Id", "size": 16, "logicalType": "uuid"}},
  {"name": "span", "type": {"type": "fixed", "name": "Span", "size": 12, "logicalType": "duration"}},
  {"name": "maybe_stamp", "type": ["null", {"type": "long", "logicalType": "timestamp-millis"}]},
  {"name": "not_a_date", "type": {"type": "string", "logicalType": "date"}},
  {"name": "unknown", "type": {"type": "int", "logicalType": "weird"}},
  {"name": "mixed_list", "type": {"type": "array", "items": ["int", "string"]}},
  {"name": "mixed_map", "type": {"type": "map", "values": ["int", "string"]}},
  {"name": "nulls", "type": {"type": "array", "items": "null"}},
  {"name": "maybe_inners", "type": ["null", {"type": "array", "items": "Inner"}]}
 ]}
''';

/// A top-level text that a Dart literal must take care with: a blank first line, CRLF, `$`,
/// backslashes, `'''`, non-ASCII and a quote at the end of a doc.
const _one =
    '  \r\n{"type": "record", "name": "One", "namespace": "test.gen",\r\n'
    ' "doc": "Costs \$5 \\\\ \\" \'\'\' \'\' ä € 😀 it\'s\'",\r\n'
    ' "fields": [{"name": "only", "type": "string"}]}\r\n';

const _empty =
    '{"type": "record", "name": "Empty", "namespace": "test.gen", "fields": []}';

final _wide =
    '{"type": "record", "name": "Wide", "namespace": "test.gen", "fields": ['
    '${[for (var i = 0; i < 21; i++) '{"name": "f$i", "type": "int"}'].join(', ')}]}';

/// A top-level union: its record is defined inline.
const _loose =
    '["null", {"type": "record", "name": "Loose", "namespace": "test.gen", '
    '"fields": [{"name": "inner", "type": {"type": "record", "name": "Deep", '
    '"fields": [{"name": "n", "type": "int"}]}}, {"name": "again", "type": "Deep"}]}]';

const _program = r'''
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';

import 'all.g.dart';
import 'minimal.g.dart';

var failures = 0;

void check(String name, bool ok) {
  if (!ok) failures++;
  print('${ok ? 'ok' : 'FAIL'} $name');
}

bool same(List<int> a, List<int> b) =>
    a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

/// Encodes [value] with TypedCodec, compares the bytes with AvroCodec's of [generic], and
/// decodes them again into [decoded] (default [value]).
void roundTrip<T>(String name, AvroType<T> type, T value, Object? generic, [T? decoded]) {
  final codec = TypedCodec(type);
  final bytes = codec.encode(value);
  check('$name: the bytes of AvroCodec',
      same(bytes, AvroCodec(writer: type.schema).encode(generic)));
  final back = codec.decode(bytes);
  check('$name: decodes back', back == (decoded ?? value));
  check('$name: equal hash codes', back.hashCode == (decoded ?? value).hashCode);
  check('$name: single-object', codec.decodeSingleObject(codec.encodeSingleObject(value)) == (decoded ?? value));
}

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  const inner = Inner(value: 7);
  const inner2 = Inner(value: 8);
  final tree = Node(label: 'root', children: [
    Node(label: 'a', children: const [], next: Node(label: 'b', children: const [])),
  ]);
  final treeGeneric = {
    'label': 'root',
    'children': [
      {'label': 'a', 'children': <Object?>[], 'next': {'label': 'b', 'children': <Object?>[], 'next': null}},
    ],
    'next': null,
  };
  final stampMs = DateTime.utc(2025, 11, 15, 10, 0, 0, 123);
  final stampUs = DateTime.utc(2025, 11, 15, 10, 0, 0, 123, 456);
  const stampNs = AvroTimestampNanos(1763200800123456789);
  final localMs = AvroLocalTimestamp.fromEpochMilliseconds(1763200800123);
  final localUs = AvroLocalTimestamp.fromEpochMicroseconds(1763200800123456);
  final localNs = AvroLocalTimestamp.fromEpochNanoseconds(1763200800123456789);
  final amount = AvroDecimal(BigInt.from(-12345), 2);
  final fixedAmount = AvroDecimal(BigInt.from(123456789012345678), 3);
  final anyAmount = AvroDecimal(BigInt.parse('-98765432109876543210'), 7);
  const id = '0b5a3c1e-4d2f-4a6b-9c8d-7e6f5a4b3c2d';
  const span = AvroDuration(1, 2, 3);
  const day = AvroDate(2025, 11, 15);

  All all({Object? either = 'text', String? maybeFirst, String? maybeLast = 'last'}) => All(
    flag: true,
    small: -5,
    big: 1 << 40,
    single: 1.5,
    real: -0.25,
    text: 'Grüße',
    raw: bytes([0, 1, 255]),
    hash: bytes([1, 2, 3, 4]),
    color: Color.green,
    maybeColor: Color.red,
    colors: [Color.green, Color.red],
    colorMap: {'g': Color.green, 'none': null},
    odd: OddNames.deviceAdd,
    numbers: [1, 2, 3],
    grid: [[1, 2], [], [3]],
    labels: {'a': 'x', 'b': 'y'},
    blobs: {'k': [bytes([9])]},
    maybeFirst: maybeFirst,
    maybeLast: maybeLast,
    maybeNumbers: [1, null, 3],
    either: either,
    inner: inner,
    maybeInner: inner2,
    inners: [inner, inner2],
    innerMap: {'one': inner, 'none': null},
    outer: Outer(inner: inner, hash: bytes([5, 6, 7, 8]), plain: const Plain(at: day)),
    tree: tree,
    class$: 1,
    hashCode$: 2,
    int$: 3,
    other$: 4,
    copyWith$: 5,
    offsetSeconds: 3600,
    httpCode: 404,
    day: day,
    timeMs: const Duration(hours: 10, milliseconds: 5),
    timeUs: const Duration(microseconds: 123456789),
    stampMs: stampMs,
    stampUs: stampUs,
    stampNs: stampNs,
    localMs: localMs,
    localUs: localUs,
    localNs: localNs,
    amount: amount,
    fixedAmount: fixedAmount,
    anyAmount: anyAmount,
    id: id,
    fixedId: id,
    span: span,
    maybeStamp: stampMs,
    notADate: '2025-11-15',
    unknown: 42,
    mixedList: [1, 'a'],
    mixedMap: {'i': 1, 's': 'a'},
    nulls: [null, null],
    maybeInners: [inner2],
  );

  Map<String, Object?> generic({Object? either = 'text', String? maybeFirst, String? maybeLast = 'last'}) => {
    'flag': true,
    'small': -5,
    'big': 1 << 40,
    'single': 1.5,
    'real': -0.25,
    'text': 'Grüße',
    'raw': bytes([0, 1, 255]),
    'hash': bytes([1, 2, 3, 4]),
    'color': 'GREEN',
    'maybe_color': 'RED',
    'colors': ['GREEN', 'RED'],
    'color_map': {'g': 'GREEN', 'none': null},
    'odd': 'DEVICE_ADD',
    'numbers': [1, 2, 3],
    'grid': [[1, 2], <Object?>[], [3]],
    'labels': {'a': 'x', 'b': 'y'},
    'blobs': {'k': [bytes([9])]},
    'maybe_first': maybeFirst,
    'maybe_last': maybeLast,
    'maybe_numbers': [1, null, 3],
    'either': either,
    'inner': {'value': 7},
    'maybe_inner': {'value': 8},
    'inners': [{'value': 7}, {'value': 8}],
    'inner_map': {'one': {'value': 7}, 'none': null},
    'outer': {'inner': {'value': 7}, 'hash': bytes([5, 6, 7, 8]), 'plain': {'at': day}},
    'tree': treeGeneric,
    'nothing': null,
    'class': 1,
    'hashCode': 2,
    'int': 3,
    'other': 4,
    'copy_with': 5,
    'offset_seconds': 3600,
    'HTTPCode': 404,
    'day': day,
    'time_ms': const Duration(hours: 10, milliseconds: 5),
    'time_us': const Duration(microseconds: 123456789),
    'stamp_ms': stampMs,
    'stamp_us': stampUs,
    'stamp_ns': stampNs,
    'local_ms': localMs,
    'local_us': localUs,
    'local_ns': localNs,
    'amount': amount,
    'fixed_amount': fixedAmount,
    'any_amount': anyAmount,
    'id': id,
    'fixed_id': id,
    'span': span,
    'maybe_stamp': stampMs,
    'not_a_date': '2025-11-15',
    'unknown': 42,
    'mixed_list': [1, 'a'],
    'mixed_map': {'i': 1, 's': 'a'},
    'nulls': [null, null],
    'maybe_inners': [{'value': 8}],
  };

  roundTrip('all', All.avroType, all(), generic());
  roundTrip('all with nulls', All.avroType, all(maybeFirst: 'first', maybeLast: null),
      generic(maybeFirst: 'first', maybeLast: null));
  // 5 fits int and long: the caller names the branch, and decoding gives the plain value.
  roundTrip('all with a Branch', All.avroType, all(either: const Branch('long', 5)),
      generic(either: const Branch('long', 5)), all(either: 5));
  check('toAvro is the generic value', jsonEncode(All.avroType.toAvro(all()), toEncodable: (o) => '$o') ==
      jsonEncode(generic(), toEncodable: (o) => '$o'));

  roundTrip('node', Node.avroType, tree, treeGeneric);
  roundTrip('inner', Inner.avroType, inner, {'value': 7});
  roundTrip('plain', Plain.avroType, const Plain(at: day), {'at': day});
  roundTrip('empty', Empty.avroType, const Empty(), <String, Object?>{});
  roundTrip('one', One.avroType, const One(only: 'x'), {'only': 'x'});
  final wide = Wide(f0: 0, f1: 1, f2: 2, f3: 3, f4: 4, f5: 5, f6: 6, f7: 7, f8: 8, f9: 9,
      f10: 10, f11: 11, f12: 12, f13: 13, f14: 14, f15: 15, f16: 16, f17: 17, f18: 18,
      f19: 19, f20: 20);
  roundTrip('wide', Wide.avroType, wide, {for (var i = 0; i < 21; i++) 'f$i': i});
  roundTrip('loose', Loose.avroType, const Loose(inner: Deep(n: 1), again: Deep(n: 2)),
      {'inner': {'n': 1}, 'again': {'n': 2}});
  roundTrip('bag', Bag.avroType, Bag(items: bytes([1, 2])), {'items': bytes([1, 2])});
  check('bag hash', Bag(items: bytes([1, 2])).hashCode == Bag(items: bytes([1, 2])).hashCode);
  roundTrip('void', Void.avroType, const Void(), {'nothing': null});
  check('enum values', OddNames.values.map((v) => v.name).join(' ') ==
      r'class$ values$ index$ name$ symbol$ deviceAdd httpCode');
  check('enum symbols', OddNames.values.map((v) => v.symbol).join(' ') ==
      'class values index name symbol DEVICE_ADD HTTPCode');
  check('fromSymbol', OddNames.fromSymbol('HTTPCode') == OddNames.httpCode);
  try {
    OddNames.fromSymbol('NOPE');
    check('fromSymbol of an unknown symbol throws', false);
  } on ArgumentError {
    check('fromSymbol of an unknown symbol throws', true);
  }
  roundTrip('paint', Paint.avroType, const Paint(shade: Shade.dark), {'shade': 'DARK'});
  // A writer symbol the reader does not know decodes to the reader's default.
  final newer = Schema.parse('{"type": "record", "name": "Paint", "fields": [{"name": "shade", '
      '"type": {"type": "enum", "name": "Shade", "symbols": ["LIGHT", "DARK", "NEON"]}}]}');
  final neon = AvroCodec(writer: newer).encode({'shade': 'NEON'});
  check('a reader enum default', TypedCodec(Paint.avroType, writer: newer).decode(neon) ==
      const Paint(shade: Shade.light));
  roundTrip('minimal', Minimal.avroType, const Minimal(name: 'n', count: 1), {'name': 'n', 'count': 1});

  check('deep equality', all() == all() && all().hashCode == all().hashCode);
  check('inequality', all() != all(either: 'other'));
  check('copyWith replaces', all().copyWith(small: 9).small == 9 && all().copyWith(small: 9).text == 'Grüße');
  check('copyWith keeps on null', all().copyWith(maybeLast: null).maybeLast == 'last');
  check('toString', const Inner(value: 7).toString() == 'Inner(value: 7)');
  check('toString of a nullable', Node(label: 'n', children: const []).toString() ==
      'Node(label: n, children: [], next: null)');
  check('toString of a \$ field', all().toString().contains(r'class$: 1,'));
  check('verbatim top-level text', One.avroType.schemaJson == File('one.avsc').readAsStringSync());
  check('verbatim all.avsc', All.avroType.schemaJson == File('all.avsc').readAsStringSync());

  // An inline type's own JSON parses on its own, with the canonical form it has inline.
  final allSchema = All.avroType.schema as RecordSchema;
  Schema fieldSchema(String name) => allSchema.fields.firstWhere((f) => f.name == name).schema;
  check('Outer stands on its own', Outer.avroType.schema.canonicalForm == fieldSchema('outer').canonicalForm);
  check('Outer keeps its attributes', (Outer.avroType.schema as RecordSchema).aliases.single == 'test.gen.Old' &&
      Outer.avroType.schema.props['my.prop'].toString() == '[1, 2]' &&
      (Outer.avroType.schema as RecordSchema).fields.first.order == 'descending');
  check('Inner keeps its doc', (Inner.avroType.schema as RecordSchema).doc == 'An inner record.');
  check('Plain is in the null namespace', (Plain.avroType.schema as RecordSchema).fullName == 'Plain');
  check('Node stands on its own', Node.avroType.schema.canonicalForm == fieldSchema('tree').canonicalForm);
  print(failures == 0 ? 'ALL OK' : '$failures FAILED');
}
''';

Future<(int, String)> _generate(List<String> args) async {
  final out = StringBuffer(), err = StringBuffer();
  final code = await runGenerate(args, out: out, err: err);
  return (code, '$out$err');
}

void main() {
  setUpAll(() {
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
    _dir.createSync(recursive: true);
  });

  void write(String name, String text) => File('${_dir.path}/$name')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  test('records generate, analyze cleanly and round-trip', () async {
    write('all.avsc', _all);
    write('one.avsc', _one);
    write('more/empty.avsc', _empty);
    write('more/wide.avsc', _wide);
    write('more/loose.avsc', _loose);
    write('more/ignored.json', '{}');
    write(
      'more/bag.avsc',
      '{"type": "record", "name": "Bag", "fields": [{"name": "items", "type": "bytes"}]}',
    );
    write(
      'more/paint.avsc',
      '{"type": "record", "name": "Paint", "fields": [{"name": "shade", "type": '
          '{"type": "enum", "name": "Shade", "symbols": ["LIGHT", "DARK"], "default": "LIGHT"}}]}',
    );
    write(
      'more/void.avsc',
      '{"type": "record", "name": "Void", "fields": [{"name": "nothing", "type": "null"}]}',
    );
    // No bytes, no collections: neither dart:typed_data nor the helpers.
    write(
      'minimal/minimal.avsc',
      '{"type": "record", "name": "Minimal", "fields": '
          '[{"name": "name", "type": "string"}, {"name": "count", "type": "long"}]}',
    );
    final minimal = '${_dir.path}/minimal.g.dart';
    final (minimalCode, minimalMessages) = await _generate([
      '${_dir.path}/minimal',
      '-o',
      minimal,
    ]);
    expect(minimalCode, 0, reason: minimalMessages);
    final minimalLibrary = File(minimal).readAsStringSync();
    expect(minimalLibrary, isNot(contains('dart:typed_data')));
    expect(minimalLibrary, isNot(contains('_deep')));
    final output = '${_dir.path}/all.g.dart';
    final (code, messages) = await _generate([
      '${_dir.path}/all.avsc',
      '${_dir.path}/one.avsc',
      '--output',
      output,
      '${_dir.path}/more',
    ]);
    expect(code, 0, reason: messages);
    final library = File(output).readAsStringSync();
    expect(
      library,
      startsWith('// Generated by avro:generate. Do not edit.\n'),
    );
    expect(
      library,
      contains(
        '// - ${_dir.path}/all.avsc\n'
        '// - ${_dir.path}/one.avsc\n'
        '// - ${_dir.path}/more/bag.avsc\n'
        '// - ${_dir.path}/more/empty.avsc\n'
        '// - ${_dir.path}/more/loose.avsc\n'
        '// - ${_dir.path}/more/paint.avsc\n'
        '// - ${_dir.path}/more/void.avsc\n'
        '// - ${_dir.path}/more/wide.avsc\n',
      ),
    );
    expect(
      library,
      contains('/// Every type, with List\\<int\\> in the doc.\n'),
    );
    expect(library, contains('  /// Its value.\n  final int value;'));
    expect(library, contains('final int class\$;'));
    expect(library, contains('/// A colour.\nenum Color {'));
    expect(library, isNot(contains('ignore')));
    // A field of the type null has no Dart field; its generic value is null.
    expect(library, isNot(contains(' nothing;')));
    expect(library, contains("'nothing': null,"));

    write('main.dart', _program);
    final analyze = await Process.run(_dart, [
      'analyze',
      '--fatal-infos',
      output,
      minimal,
    ]);
    expect(analyze.exitCode, 0, reason: '${analyze.stdout}${analyze.stderr}');
    final run = await Process.run(_dart, [
      'run',
      'main.dart',
    ], workingDirectory: _dir.path);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    expect(run.stdout, contains('ALL OK'), reason: '${run.stdout}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('failures write nothing', () {
    final output = '${_dir.path}/failed.g.dart';

    Future<String> fails(int exitCode, List<String> args) async {
      final (code, messages) = await _generate(args);
      expect(code, exitCode, reason: messages);
      expect(File(output).existsSync(), isFalse);
      return messages;
    }

    String schema(String name, String text) {
      write(name, text);
      return '${_dir.path}/$name';
    }

    test('usage errors exit with 2', () async {
      expect(await fails(2, []), contains('no schemas given'));
      expect(await fails(2, ['a.avsc']), contains('no output given'));
      expect(await fails(2, ['a.avsc', '-o']), contains('-o needs a file'));
      expect(
        await fails(2, ['--wat', 'a.avsc', '-o', output]),
        contains('--wat'),
      );
      expect(
        await fails(2, ['a.avsc', '-o', output, '--output=$output']),
        contains('twice'),
      );
    });

    test('help', () async {
      final (code, messages) = await _generate(['-h']);
      expect(code, 0);
      expect(messages, contains('Usage: dart run avro:generate'));
    });

    test('an unreadable file or a bad schema exits with 1', () async {
      final missing = '${_dir.path}/missing.avsc';
      expect(await fails(1, [missing, '-o', output]), contains(missing));
      final bad = schema('bad.avsc', '{"type": "record", "name": "Bad"}');
      expect(
        await fails(1, [bad, '-o', output]),
        allOf(contains(bad), contains('missing "fields"')),
      );
      final notJson = schema('not_json.avsc', '{');
      expect(await fails(1, [notJson, '-o', output]), contains(notJson));
    });

    test('two fields with the same Dart name', () async {
      final file = schema(
        'fields.avsc',
        '{"type": "record", "name": "R", "fields": '
            '[{"name": "a_b", "type": "int"}, {"name": "aB", "type": "int"}]}',
      );
      expect(
        await fails(1, [file, '-o', output]),
        allOf(contains(file), contains('"a_b" and "aB"'), contains('aB')),
      );
    });

    test('two records with the same class name', () async {
      final a = schema(
        'x1.avsc',
        '{"type": "record", "name": "a.X", "fields": []}',
      );
      final b = schema(
        'x2.avsc',
        '{"type": "record", "name": "b.X", "fields": []}',
      );
      expect(
        await fails(1, [a, b, '-o', output]),
        allOf(contains(b), contains('"b.X" and "a.X"'), contains(a)),
      );
      final again = schema(
        'x3.avsc',
        '{"type": "record", "name": "a.X", "fields": []}',
      );
      expect(
        await fails(1, [a, again, '-o', output]),
        allOf(contains(again), contains('already defined in $a')),
      );
    });

    test('two symbols with the same Dart name', () async {
      final file = schema(
        'symbols.avsc',
        '{"type": "enum", "name": "E", "symbols": ["A_B", "aB"]}',
      );
      expect(
        await fails(1, [file, '-o', output]),
        allOf(contains(file), contains('"A_B" and "aB"'), contains('"E"')),
      );
    });

    test('a class name of dart:core', () async {
      final file = schema(
        'core.avsc',
        '{"type": "record", "name": "axt.DateTime", "fields": []}',
      );
      expect(
        await fails(1, [file, '-o', output]),
        allOf(contains(file), contains('DateTime'), contains('prefix')),
      );
    });
  });
}
