// Needs dart:io, or test data read from files: not one of the web tests.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:avro/avro.dart';
import 'package:avro/src/generate/command.dart';
import 'package:test/test.dart';

import 'data/axt/axt_types.g.dart';

/// The command that wrote test/data/axt/axt_types.g.dart, as test/data/axt/README.md gives it.
const _arguments = [
  'test/data/axt/types',
  '--prefix',
  'axt=Axt',
  '--prefix',
  'axt.example.v1=AxtExample',
];

Uint8List _hexFile(String path) {
  final hex = File(path).readAsStringSync().trim();
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

void main() {
  test('the committed library is what the command writes now', () async {
    final dir = Directory('.dart_tool/axt_types_test')
      ..createSync(recursive: true);
    final output = '${dir.path}/axt_types.g.dart';
    final err = StringBuffer();
    final code = await runGenerate(
      [..._arguments, '-o', output],
      out: StringBuffer(),
      err: err,
    );
    expect(code, 0, reason: '$err');
    expect(err.toString(), isEmpty);
    expect(
      File(output).readAsBytesSync(),
      File('test/data/axt/axt_types.g.dart').readAsBytesSync(),
      reason:
          'test/data/axt/axt_types.g.dart is out of date; run the command of '
          'test/data/axt/README.md',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the message of spec/envelope.md, section 10.2, decodes typed', () {
    final message = _hexFile('test/data/axt/memo-message.hex');
    expect(message, hasLength(210));
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
    expect(envelope.sender, hasLength(32));
    expect(envelope.signature, hasLength(64));
    expect(envelope.body, hasLength(62));

    // com.example.Memo is the illustration of spec/envelope.md, not one of the AXT types, so
    // it has no class: its body decodes with the generic codec, and its time as AxtDateTime.
    final memos = AvroCodec(
      writer: Schema.parse(
        File('test/data/axt/memo-canonical.json').readAsStringSync(),
      ),
    );
    final memo =
        memos.decodeSingleObject(envelope.body)! as Map<String, Object?>;
    expect(memo['text'], 'Vet, Tuesday 10:00');
    final written = AxtDateTime.avroType.fromAvro(memo['written']);
    expect(
      written,
      const AxtDateTime(
        year: 2025,
        month: 11,
        day: 15,
        hour: 11,
        minute: 0,
        second: 0,
        millisecond: 0,
        zone: 'Europe/Berlin',
        offsetSeconds: 3600,
        instantMs: 1763200800000,
      ),
    );

    final body = memos.encodeSingleObject({
      'text': memo['text'],
      'written': AxtDateTime.avroType.toAvro(written),
    });
    expect(body, envelope.body);
    expect(
      envelopes.encodeSingleObject(envelope.copyWith(body: body)),
      message,
    );
  });

  test('values of the example types round-trip', () {
    const due = AxtDateTime(
      year: 2026,
      month: 1,
      day: 2,
      hour: 9,
      minute: 30,
      second: 0,
      millisecond: 0,
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
    expect(tasks.decode(tasks.encode(task.copyWith(done: true))).done, isTrue);

    final note = AxtExampleNote(
      title: 'Groceries',
      text: '- milk\n- bread',
      format: AxtExampleNoteFormat.markdown,
      created: due,
      tags: const ['home', 'list'],
    );
    final notes = TypedCodec(AxtExampleNote.avroType);
    final bytes = notes.encodeSingleObject(note);
    expect(notes.decodeSingleObject(bytes), note);
    expect(
      bytes,
      AvroCodec(writer: AxtExampleNote.avroType.schema)
          .encodeSingleObject(AxtExampleNote.avroType.toAvro(note)),
    );
  });
}
