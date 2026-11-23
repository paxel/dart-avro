@Tags(['web'])
library;

import 'package:avro/avro.dart';
import 'package:test/test.dart';

import '../data/axt/axt_types.g.dart';
import 'files.dart';

void main() {
  test('the message of spec/envelope.md, section 10.2, decodes typed', () {
    final message = webHex('axt/memo-message.hex');
    final envelopes = TypedCodec(AxtEnvelope.avroType);
    final envelope = envelopes.decodeSingleObject(message);
    expect(envelope.format, 1);
    expect(envelope.kind, AxtKind.data);
    expect(
      envelope.record,
      const AxtRecordRef(
        id: '0b5a3c1e-4d2f-4a6b-9c8d-7e6f5a4b3c2d',
        version: 1,
      ),
    );
    expect(envelope.body, hasLength(62));
    expect(envelopes.encodeSingleObject(envelope), message);
  });

  test('values of the generated classes round-trip', () {
    const due = AxtDateTime(
      year: 2026,
      month: 1,
      day: 2,
      hour: 9,
      minute: 30,
      second: 0,
      millisecond: 0,
      zone: 'Europe/Berlin',
      offsetSeconds: 3600,
      instantMs: 1767342600000,
    );
    final task = AxtExampleTask(
      title: 'Vet',
      notes: 'Bring the papers',
      due: due,
      dueAllDay: false,
      done: false,
      priority: AxtExampleTaskPriority.high,
    );
    final tasks = TypedCodec(AxtExampleTask.avroType);
    expect(tasks.decode(tasks.encode(task)), task);
    expect(tasks.decodeJson(tasks.encodeJson(task)), task);
  });
}
