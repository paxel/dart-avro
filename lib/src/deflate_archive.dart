// Raw DEFLATE through archive's pure-Dart Inflate and Deflate, for the platforms without
// dart:io such as the web. deflate_io.dart is the same API through dart:io's zlib (ADR 11).

import 'dart:typed_data';

import 'package:archive/archive.dart'
    show
        Inflate,
        InputMemoryStream,
        InputStream,
        OutputMemoryStream,
        ZLibEncoderWeb;

/// [data] compressed with raw DEFLATE, without a zlib header.
Uint8List deflateRaw(Uint8List data) =>
    const ZLibEncoderWeb().encodeBytes(data, raw: true);

/// [data] inflated from raw DEFLATE.
///
/// [check] is called with the output length before each write to the output, and stops the
/// inflating by throwing; what it throws comes out unchanged. Data that is not DEFLATE, or
/// that ends before its final block, throws a [FormatException].
Uint8List inflateRaw(Uint8List data, void Function(int length) check) {
  final out = _CheckedOutput(check);
  final inflate = Inflate.lazy(InputMemoryStream(data), output: out);
  // Throws archive's ArchiveException, a FormatException, for data that is not DEFLATE,
  // including the RangeError of data that ends inside a block.
  while (inflate.inflateBlock()) {}
  return out.getBytes();
}

/// The output of [Inflate], written to directly as an [OutputMemoryStream] is, with
/// [check] called before every write: any other output is only filled between DEFLATE
/// blocks, and one block can inflate to gigabytes.
final class _CheckedOutput extends OutputMemoryStream {
  _CheckedOutput(this.check);

  final void Function(int length) check;

  @override
  void writeByte(int value) {
    check(length + 1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    check(this.length + (length ?? bytes.length));
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    check(length + stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    check(length + count);
    super.writeBackReference(distance, count);
  }
}
