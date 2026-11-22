// The platform check of ADR 11: Avro's `long` needs a 64-bit `int`, which dart2js, where an
// `int` is a JavaScript number, does not have. The VM, AOT and dart2wasm do.

/// The message of the [UnsupportedError] that [checkPlatform] throws under dart2js.
const unsupportedPlatformMessage =
    'avro needs 64-bit integers: compile for the web with dart2wasm';

/// Throws [UnsupportedError] if `int` is not 64-bit, as under dart2js.
void checkPlatform() => checkIntegers(jsNumbers: identical(0, 0.0));

/// Throws [UnsupportedError] if [jsNumbers]: integers are JavaScript numbers, as under
/// dart2js, where `0` and `0.0` are the same object.
void checkIntegers({required bool jsNumbers}) {
  if (jsNumbers) throw UnsupportedError(unsupportedPlatformMessage);
}
