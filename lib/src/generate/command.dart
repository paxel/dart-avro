/// The command `dart run avro:generate`.
library;

import 'dart:io';

import 'library.dart';

const _usage = '''
Usage: dart run avro:generate <schemas...> -o <file>

Writes one Dart library with an immutable class for every record of the schemas.

  <schemas...>         .avsc files, or directories searched for .avsc files
  -o, --output <file>  the Dart file to write
  --prefix <ns>=<P>    put P before the names of the types of the namespace ns, as in
                       --prefix axt=Axt for AxtDateTime; repeatable
  -h, --help           print this help''';

final _namespace = RegExp(
  r'^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$',
);
final _prefix = RegExp(r'^[A-Z][A-Za-z0-9]*$');

/// Runs the command with [args], writing messages to [out] and [err]; returns the exit code:
/// 0 on success, 2 for a usage error, 1 for any other failure. Nothing is written on a
/// failure.
Future<int> runGenerate(
  List<String> args, {
  required StringSink out,
  required StringSink err,
}) async {
  final inputs = <String>[];
  final prefixes = <String, String>{};
  String? output;
  int usage(String message) {
    err
      ..writeln('avro:generate: $message')
      ..writeln()
      ..writeln(_usage);
    return 2;
  }

  var options = true;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (options && a == '--') {
      options = false;
    } else if (options && (a == '-h' || a == '--help')) {
      out.writeln(_usage);
      return 0;
    } else if (options &&
        (a == '-o' || a == '--output' || a.startsWith('--output='))) {
      if (output != null) return usage('the output is given twice');
      if (a.startsWith('--output=')) {
        output = a.substring('--output='.length);
      } else if (i + 1 < args.length) {
        output = args[++i];
      } else {
        return usage('$a needs a file');
      }
      if (output.isEmpty) return usage('$a needs a file');
    } else if (options && (a == '--prefix' || a.startsWith('--prefix='))) {
      final String value;
      if (a.startsWith('--prefix=')) {
        value = a.substring('--prefix='.length);
      } else if (i + 1 < args.length) {
        value = args[++i];
      } else {
        return usage('--prefix needs <namespace>=<Prefix>');
      }
      final eq = value.indexOf('=');
      final namespace = eq < 0 ? '' : value.substring(0, eq);
      final prefix = eq < 0 ? '' : value.substring(eq + 1);
      if (!_namespace.hasMatch(namespace) || !_prefix.hasMatch(prefix)) {
        return usage(
          '--prefix "$value" is not <namespace>=<Prefix>, with a Prefix in '
          'UpperCamelCase such as axt=Axt',
        );
      }
      if (prefixes.containsKey(namespace)) {
        return usage('the namespace $namespace has two prefixes');
      }
      prefixes[namespace] = prefix;
    } else if (options && a.startsWith('-') && a != '-') {
      return usage('unknown option $a');
    } else {
      inputs.add(a);
    }
  }
  if (inputs.isEmpty) return usage('no schemas given');
  if (output == null) return usage('no output given (-o <file>)');

  try {
    final files = await _schemaFiles(inputs);
    final library = generateLibrary(
      files,
      prefixes: prefixes,
      warn: (message) => err.writeln('avro:generate: warning: $message'),
    );
    await _write(output, library);
  } on GenerateException catch (e) {
    err.writeln('avro:generate: ${e.message}');
    return 1;
  }
  return 0;
}

/// The paths of the schema files: each input in the order given, a directory as its `.avsc`
/// files, searched recursively and sorted by path. A file reached twice is read once.
Future<List<SchemaFile>> _schemaFiles(List<String> inputs) async {
  final paths = <String>[];
  for (final input in inputs) {
    if (await FileSystemEntity.isDirectory(input)) {
      final found = <String>[];
      try {
        await for (final e in Directory(input).list(recursive: true)) {
          if (e is File && e.path.endsWith('.avsc')) found.add(e.path);
        }
      } on FileSystemException catch (e) {
        throw GenerateException('$input: ${e.message}');
      }
      paths.addAll(found..sort());
    } else {
      paths.add(input);
    }
  }
  final seen = <String>{};
  final files = <SchemaFile>[];
  for (final path in paths) {
    if (!seen.add(File(path).absolute.path)) continue;
    try {
      files.add((path: path, text: await File(path).readAsString()));
    } on FileSystemException catch (e) {
      throw GenerateException(
        '$path: cannot read: ${e.osError?.message ?? e.message}',
      );
    } on FormatException {
      throw GenerateException('$path: not UTF-8 text');
    }
  }
  if (files.isEmpty) {
    throw GenerateException('no .avsc files in ${inputs.join(', ')}');
  }
  return files;
}

/// Writes [library] to [path] and formats it with `dart format` there, so that the format
/// follows the language version of the package it is in. Restores the previous file if
/// formatting fails.
Future<void> _write(String path, String library) async {
  final file = File(path);
  final previous = await file.exists() ? await file.readAsBytes() : null;
  try {
    await file.writeAsString(library);
  } on FileSystemException catch (e) {
    throw GenerateException(
      '$path: cannot write: ${e.osError?.message ?? e.message}',
    );
  }
  final executable =
      Platform.resolvedExecutable.split(Platform.pathSeparator).last ==
          (Platform.isWindows ? 'dart.exe' : 'dart')
      ? Platform.resolvedExecutable
      : 'dart';
  String? failure;
  try {
    final result = await Process.run(executable, ['format', path]);
    if (result.exitCode != 0) {
      failure = '${result.stderr}${result.stdout}'.trim();
    }
  } on ProcessException catch (e) {
    failure = e.message;
  }
  if (failure != null) {
    if (previous == null) {
      await file.delete();
    } else {
      await file.writeAsBytes(previous);
    }
    throw GenerateException('$path: dart format failed: $failure');
  }
}
