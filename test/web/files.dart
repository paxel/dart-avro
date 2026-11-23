import 'dart:convert';
import 'dart:typed_data';

import 'data.g.dart';

/// The bytes of [name] under test/data, from the generated constants.
Uint8List webBytes(String name) => base64Decode(
  webTestFiles[name] ??
      (throw ArgumentError.value(
        name,
        'name',
        'is not in tool/web_test_data.dart',
      )),
);

/// The UTF-8 text of [name] under test/data.
String webText(String name) => utf8.decode(webBytes(name));

/// The bytes written as hexadecimal in [name] under test/data.
Uint8List webHex(String name) {
  final hex = webText(name).trim();
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// The records of Apache Avro's weather files, from weather.json.
List<Object?> weatherRecords() => [
  for (final line in const LineSplitter().convert(
    webText('apache/weather.json'),
  ))
    if (line.isNotEmpty) jsonDecode(line),
];
