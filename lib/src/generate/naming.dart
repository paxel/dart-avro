/// The Dart names of generated classes and fields.
library;

/// The reserved words of Dart: no field can have one as its name.
const _reservedWords = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

/// The names a field cannot take in a generated class: the members the class declares or
/// inherits, the lower-case types its code names, and the parameter of `==`.
const _takenNames = {
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
  'copyWith',
  'avroType',
  'toAvro',
  'fromAvro',
  'bool',
  'int',
  'double',
  'num',
  'other',
};

/// The type names of `dart:core` and of the other libraries the generated code uses. A class
/// with one of these names would hide that type.
const clashingTypeNames = {
  'ArgumentError',
  'AssertionError',
  'BigInt',
  'Comparable',
  'Comparator',
  'ConcurrentModificationError',
  'DateTime',
  'Deprecated',
  'Duration',
  'Enum',
  'Error',
  'Exception',
  'Expando',
  'Finalizer',
  'FormatException',
  'Function',
  'Future',
  'IndexError',
  'IntegerDivisionByZeroException',
  'Invocation',
  'Iterable',
  'Iterator',
  'List',
  'Map',
  'MapEntry',
  'Match',
  'Never',
  'NoSuchMethodError',
  'Null',
  'Object',
  'OutOfMemoryError',
  'Pattern',
  'RangeError',
  'Record',
  'RegExp',
  'RegExpMatch',
  'RuneIterator',
  'Runes',
  'Set',
  'Sink',
  'StackOverflowError',
  'StackTrace',
  'StateError',
  'Stopwatch',
  'Stream',
  'String',
  'StringBuffer',
  'StringSink',
  'Symbol',
  'Type',
  'TypeError',
  'UnimplementedError',
  'UnsupportedError',
  'Uri',
  'UriData',
  'WeakReference',
  // dart:typed_data
  'Uint8List',
  // package:avro
  'AvroType',
  'AvroDate',
  'AvroDecimal',
  'AvroDuration',
  'AvroLocalTimestamp',
  'AvroTimestampNanos',
};

/// The words of an Avro name: split at underscores and where the case changes, so that
/// `offset_seconds`, `offsetSeconds` and `OFFSET_SECONDS` all give `offset` and `seconds`, and
/// `HTTPCode` gives `HTTP` and `Code`.
List<String> _words(String name) {
  final words = <String>[];
  for (final part in name.split('_')) {
    var start = 0;
    for (var i = 1; i < part.length; i++) {
      final prev = part[i - 1], c = part[i];
      final next = i + 1 < part.length ? part[i + 1] : '';
      final lowerToUpper = _isLower(prev) || _isDigit(prev)
          ? _isUpper(c)
          : false;
      final acronymEnd = _isUpper(prev) && _isUpper(c) && _isLower(next);
      if (lowerToUpper || acronymEnd) {
        words.add(part.substring(start, i));
        start = i;
      }
    }
    if (start < part.length) words.add(part.substring(start));
  }
  return words;
}

bool _isUpper(String c) => c != c.toLowerCase();
bool _isLower(String c) => c != c.toUpperCase();
bool _isDigit(String c) => '0123456789'.contains(c);

String _capitalized(String word) =>
    word[0].toUpperCase() + word.substring(1).toLowerCase();

final _lowerCamel = RegExp(r'^[a-z][a-zA-Z0-9]*$');
final _upperCamel = RegExp(r'^[A-Z][a-zA-Z0-9]*$');

/// The names an enum value cannot take: the members of a generated enum.
const _takenByEnums = {
  'values',
  'index',
  'name',
  'symbol',
  'fromSymbol',
  'compareTo',
};

/// The Dart name of an Avro field: lowerCamelCase, with a `$` suffix where the name is a
/// reserved word or taken by the generated class. Null if the name has no letter to start
/// with.
String? fieldName(String avroName) => _memberName(avroName, _takenNames);

/// The Dart name of an Avro enum symbol, as [fieldName] gives it, with a `$` suffix also
/// where the name is taken by the generated enum.
String? enumValueName(String symbol) =>
    _memberName(symbol, {..._takenNames, ..._takenByEnums});

String? _memberName(String avroName, Set<String> taken) {
  String name;
  if (_lowerCamel.hasMatch(avroName)) {
    name = avroName;
  } else {
    final words = _words(avroName);
    if (words.isEmpty) return null;
    name = [
      words.first.toLowerCase(),
      for (final w in words.skip(1)) _capitalized(w),
    ].join();
  }
  if (!_lowerCamel.hasMatch(name)) return null;
  return _reservedWords.contains(name) || taken.contains(name)
      ? '$name\$'
      : name;
}

/// The Dart name of an Avro named type: UpperCamelCase. Null if the name has no letter to
/// start with.
String? className(String avroName) {
  if (_upperCamel.hasMatch(avroName)) return avroName;
  final words = _words(avroName);
  final name = [for (final w in words) _capitalized(w)].join();
  return _upperCamel.hasMatch(name) ? name : null;
}
