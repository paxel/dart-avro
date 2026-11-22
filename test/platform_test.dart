import 'package:avro/src/platform.dart';
import 'package:test/test.dart';

void main() {
  test('the message asks for dart2wasm', () {
    expect(
      unsupportedPlatformMessage,
      'avro needs 64-bit integers: compile for the web with dart2wasm',
    );
  });

  test('JavaScript numbers are refused with UnsupportedError', () {
    expect(
      () => checkIntegers(jsNumbers: true),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          unsupportedPlatformMessage,
        ),
      ),
    );
  });

  test('the VM has 64-bit integers', () {
    expect(identical(0, 0.0), isFalse);
    expect(checkPlatform, returnsNormally);
  });
}
