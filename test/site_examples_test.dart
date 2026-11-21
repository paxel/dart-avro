// Runs every Dart example of the documentation site (avro-1012), so that no page shows code
// that does not compile, does not run, or prints something else than the page says.
//
// An example is `<pre data-example="NAME"><code class="language-dart">…</code></pre>`: a
// complete program with `main()`. It may be followed by `<pre data-example-output="NAME">`
// with its exact output. Every other `<pre>` must say `data-fragment`, so nothing slips through
// untested.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

final class _Block {
  _Block(this.page, this.attributes, this.code);

  final String page;
  final String attributes;
  final String code;

  String? attribute(String name) =>
      RegExp('\\s$name\\s*=\\s*"([^"]*)"').firstMatch(attributes)?.group(1);

  bool has(String name) =>
      RegExp('\\s$name(?=[\\s=>]|\$)').hasMatch(attributes);
}

final _pre = RegExp(
  r'<pre(\s[^>]*)?>\s*<code(\s[^>]*)?>([\s\S]*?)</code>\s*</pre>',
);

/// The text of an HTML-escaped code block; `&amp;` last, so that `&amp;lt;` stays `&lt;`.
String _unescape(String html) => html
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

String _trimLines(String text) =>
    text.split('\n').map((line) => line.trimRight()).join('\n').trimRight();

List<_Block> _blocks() {
  final pages =
      Directory('site')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.html'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in pages)
      for (final m in _pre.allMatches(file.readAsStringSync()))
        _Block(
          file.path,
          '${m.group(1) ?? ''} ${m.group(2) ?? ''}',
          _unescape(m.group(3)!),
        ),
  ];
}

/// Runs [tasks] with at most [width] of them at once.
Map<String, Future<ProcessResult>> _pool(
  Map<String, Future<ProcessResult> Function()> tasks,
  int width,
) {
  final pending = tasks.entries.toList();
  final results = {
    for (final name in tasks.keys) name: Completer<ProcessResult>(),
  };
  Future<void> worker() async {
    while (pending.isNotEmpty) {
      final task = pending.removeAt(0);
      final completer = results[task.key]!;
      try {
        completer.complete(await task.value());
      } on Object catch (e, s) {
        completer.completeError(e, s);
      }
    }
  }

  for (var i = 0; i < width; i++) {
    unawaited(worker());
  }
  return {for (final e in results.entries) e.key: e.value.future};
}

void main() {
  final blocks = _blocks();
  final examples = <String, _Block>{};
  final outputs = <String, _Block>{};

  test('every code block is an example, an output or a fragment', () {
    final problems = <String>[];
    for (final b in blocks) {
      final example = b.attribute('data-example');
      final output = b.attribute('data-example-output');
      final marks = [example, output, if (b.has('data-fragment')) ''];
      if (marks.whereType<String>().length != 1) {
        problems.add(
          '${b.page}: a <pre> needs exactly one of data-example, data-example-output '
          'and data-fragment: ${b.code.split('\n').first}',
        );
      }
      if (example != null &&
          !RegExp(r'class="[^"]*\blanguage-dart\b').hasMatch(b.attributes)) {
        problems.add('${b.page}: the example $example is not language-dart');
      }
    }
    final pres = Directory('site')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.html'))
        .map(
          (f) => RegExp(r'<pre[\s>]').allMatches(f.readAsStringSync()).length,
        )
        .fold(0, (a, b) => a + b);
    if (pres != blocks.length) {
      problems.add('a <pre> holds something else than one <code>');
    }
    expect(problems, isEmpty);
  });

  for (final b in blocks) {
    final example = b.attribute('data-example');
    final output = b.attribute('data-example-output');
    if (example != null) {
      if (examples.containsKey(example)) {
        test('the example $example is named once', () => fail(b.page));
      }
      examples[example] = b;
    }
    if (output != null) {
      if (outputs.containsKey(output)) {
        test('the output $output is named once', () => fail(b.page));
      }
      outputs[output] = b;
    }
  }

  test('every output belongs to an example', () {
    expect(outputs.keys.where((name) => !examples.containsKey(name)), isEmpty);
  });

  final dir = Directory('.dart_tool/site_examples');
  late Map<String, Future<ProcessResult>> runs;

  setUpAll(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    runs = _pool({
      for (final MapEntry(key: name, value: b) in examples.entries)
        name: () {
          final file = File(
            '${dir.path}/${name.replaceAll(RegExp('[^A-Za-z0-9_]'), '_')}.dart',
          )..writeAsStringSync(b.code);
          return Process.run(Platform.resolvedExecutable, ['run', file.path]);
        },
    }, 2);
  });

  for (final MapEntry(key: name, value: b) in examples.entries) {
    test('the example $name of ${b.page} runs', () async {
      final result = await runs[name]!;
      final stdout = _trimLines(result.stdout as String);
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n$stdout\nstderr:\n${result.stderr}',
      );
      final expected = outputs[name];
      if (expected != null) {
        expect(stdout, _trimLines(expected.code), reason: 'stdout:\n$stdout');
      }
    });
  }
}
