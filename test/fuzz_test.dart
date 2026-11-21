import 'dart:math';

import 'package:test/test.dart';

import '../tool/fuzz/targets.dart';

void main() {
  final codecs = fuzzCodecs();
  final seeds = fuzzSeeds(codecs);

  test('the seeds are accepted or rejected with an AvroException', () async {
    for (final seed in seeds) {
      expect(fuzzOne(seed, codecs) ?? await fuzzStream(seed), isNull);
    }
  });

  test(
    '2,000 mutations with a fixed seed throw nothing but AvroException',
    () async {
      final random = Random(20261121);
      for (var i = 0; i < 2000; i++) {
        final input = mutate(seeds[random.nextInt(seeds.length)], random);
        final failure = fuzzOne(input, codecs) ?? await fuzzStream(input);
        expect(failure, isNull, reason: '$failure');
      }
    },
  );
}
