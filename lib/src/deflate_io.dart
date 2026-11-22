// Raw DEFLATE through dart:io's zlib, on the VM and AOT. deflate_archive.dart is the same
// API in pure Dart for the platforms without dart:io (ADR 11).

import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:typed_data';

/// [data] compressed with raw DEFLATE, without a zlib header.
Uint8List deflateRaw(Uint8List data) {
  final out = ZLibEncoder(raw: true).convert(data);
  return out is Uint8List ? out : Uint8List.fromList(out);
}

/// [data] inflated from raw DEFLATE.
///
/// [check] is called with the output length each time the output grows, and stops the
/// inflating by throwing; what it throws comes out unchanged. Data that is not DEFLATE
/// throws a [FormatException].
Uint8List inflateRaw(Uint8List data, void Function(int length) check) {
  final out = _CheckedSink(check);
  final sink = ZLibDecoder(raw: true).startChunkedConversion(out);
  const chunk = 4096;
  for (var i = 0; i < data.length; i += chunk) {
    sink.add(
      Uint8List.sublistView(
        data,
        i,
        i + chunk < data.length ? i + chunk : data.length,
      ),
    );
  }
  sink.close();
  return out.bytes.takeBytes();
}

final class _CheckedSink implements Sink<List<int>> {
  _CheckedSink(this.check);

  final void Function(int length) check;
  final BytesBuilder bytes = BytesBuilder(copy: true);

  @override
  void add(List<int> chunk) {
    bytes.add(chunk);
    check(bytes.length);
  }

  @override
  void close() {}
}
