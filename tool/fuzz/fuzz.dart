// Mutation fuzzing of the decoder and the container file readers (avro-1010).
//
//   dart run tool/fuzz/fuzz.dart [seconds] [seed]
//
// Mutates valid inputs at random for the given time (default 60 seconds) and fails on the
// first input that throws anything other than an AvroException, or that takes longer than
// two seconds. The input that failed is written to fuzz/artifacts/fuzz/crash-<sha256>, where
// the shared fuzz workflow of paxel/gates keeps it. Run from the repository root.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'targets.dart';

Future<void> main(List<String> args) async {
  final seconds = args.isNotEmpty ? int.parse(args[0]) : 60;
  final seed = args.length > 1
      ? int.parse(args[1])
      : DateTime.now().microsecondsSinceEpoch;
  final random = Random(seed);
  final codecs = fuzzCodecs();
  final seeds = fuzzSeeds(codecs);
  final end = DateTime.now().add(Duration(seconds: seconds));
  var runs = 0;
  stdout.writeln('fuzzing for $seconds s, seed $seed');
  while (DateTime.now().isBefore(end)) {
    final input = mutate(seeds[random.nextInt(seeds.length)], random);
    final watch = Stopwatch()..start();
    final failure = fuzzOne(input, codecs) ?? await fuzzStream(input);
    if (failure != null) {
      stderr.writeln(failure);
      keepCrash(input);
      exit(1);
    }
    if (watch.elapsed > const Duration(seconds: 2)) {
      stderr.writeln('an input took ${watch.elapsed}: ${input.length} bytes');
      keepCrash(input);
      exit(1);
    }
    runs++;
  }
  stdout.writeln('$runs inputs, no failure');
}

/// Writes [input] where the shared fuzz workflow uploads it.
void keepCrash(Uint8List input) {
  final file = File('fuzz/artifacts/fuzz/crash-${sha256.convert(input)}')
    ..createSync(recursive: true)
    ..writeAsBytesSync(input);
  stderr.writeln('kept in ${file.path}');
}
