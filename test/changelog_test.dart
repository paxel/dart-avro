// Needs dart:io, or test data read from files: not one of the web tests.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('CHANGELOG.md holds exactly the section of the pubspec version', () {
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())?.group(1);
    final sections = RegExp(r'^## \[([^\]]+)\]', multiLine: true)
        .allMatches(File('CHANGELOG.md').readAsStringSync())
        .map((m) => m.group(1))
        .toList();
    expect(sections, [version]);
  });
}
