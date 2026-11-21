import 'dart:io';

import 'package:avro/src/generate/command.dart';

/// `dart run avro:generate <schemas...> -o <file>`: writes the Dart classes of Avro schemas.
Future<void> main(List<String> args) async {
  exitCode = await runGenerate(args, out: stdout, err: stderr);
}
