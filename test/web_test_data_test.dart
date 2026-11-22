@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../tool/web_test_data.dart';

void main() {
  test('test/web/data.g.dart is what tool/web_test_data.dart writes now', () {
    expect(
      File(webTestDataPath).readAsStringSync(),
      webTestData(),
      reason:
          '$webTestDataPath is out of date; run dart run tool/web_test_data.dart',
    );
  });
}
