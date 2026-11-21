import 'dart:math';

import 'package:test/test.dart';

import '../tool/fuzz/targets.dart';

void main() {
  final codecs = fuzzCodecs();
  final seeds = fuzzSeeds(codecs);

  test('the seeds are accepted or rejected with an AvroException', () {
    for (final seed in seeds) {
      expect(fuzzOne(seed, codecs), isNull);
    }
  });

  test('2,000 mutations with a fixed seed throw nothing but AvroException', () {
    final random = Random(20261121);
    for (var i = 0; i < 2000; i++) {
      final input = mutate(seeds[random.nextInt(seeds.length)], random);
      final failure = fuzzOne(input, codecs);
      expect(failure, isNull, reason: '$failure');
    }
  });
}
