/// One case of Apache Avro's share/test/data/schema-tests.txt.
typedef SchemaCase = ({
  String id,
  String input,
  String canonical,
  int? fingerprint,
});

/// The cases of the text of schema-tests.txt.
List<SchemaCase> parseSchemaTests(String text) {
  final cases = <SchemaCase>[];
  final lines = text.split('\n');
  String? id;
  final values = <String, String>{};
  void flush() {
    if (id != null && values.containsKey('INPUT')) {
      cases.add((
        id: id,
        input: values['INPUT']!,
        canonical: values['canonical']!,
        fingerprint: switch (values['fingerprint']) {
          final String f => int.parse(f),
          null => null,
        },
      ));
    }
    values.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final idMatch = RegExp(r'^// (\d{3})').firstMatch(line);
    if (idMatch != null) {
      flush();
      id = idMatch.group(1);
      continue;
    }
    final m = RegExp(r'^<<(\w+)(?: (.*))?$').firstMatch(line);
    if (m == null) continue;
    final key = m.group(1)!;
    if (m.group(2) != null) {
      values[key] = m.group(2)!;
    } else {
      // A heredoc: the lines up to the one that holds only the key.
      final body = <String>[];
      while (lines[++i] != key) {
        body.add(lines[i]);
      }
      values[key] = body.join('\n');
    }
  }
  flush();
  return cases;
}
