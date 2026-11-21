import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'binary.dart';
import 'codec.dart';
import 'exceptions.dart';
import 'limits.dart';
import 'schema.dart';

/// The magic at the start of every object container file: `Obj` and the byte 1.
const containerMagic = [0x4f, 0x62, 0x6a, 0x01];

/// The compressions this package reads and writes.
const supportedCompressions = {'null', 'deflate'};

/// The header of an object container file.
final class AvroFileHeader {
  AvroFileHeader._(
    Map<String, Uint8List> metadata,
    this.schemaJson,
    this.compression,
    this.syncMarker,
  ) : metadata = Map.unmodifiable(metadata);

  /// Every metadata entry, in the order of the file, with its value as stored.
  final Map<String, Uint8List> metadata;

  /// The text of `avro.schema`: the writer schema as JSON.
  final String schemaJson;

  /// How the blocks are compressed: `null` or `deflate`, the file's `avro.codec`.
  final String compression;

  /// The 16 bytes that end every block.
  final Uint8List syncMarker;
}

/// Reads an object container file held in memory.
///
/// The constructor reads the header only. Throws [DecodeException] if it is not a container
/// file, and [UnsupportedCompressionException] if its blocks use a compression other than
/// `null` and `deflate`.
final class AvroFileReader {
  AvroFileReader(Uint8List bytes, {this.limits = const AvroLimits()})
    : _bytes = bytes {
    final input = BinaryReader(bytes);
    for (final b in containerMagic) {
      if (input.remaining == 0 || input.readByte() != b) {
        throw const DecodeException(
          'not an Avro container file: the magic "Obj" 1 is missing',
          offset: 0,
        );
      }
    }
    final metadata = <String, Uint8List>{};
    while (true) {
      final start = input.offset;
      var count = input.readLong();
      if (count == 0) break;
      if (count < 0) {
        if (count == -0x8000000000000000) input.fail('invalid count', start);
        count = -count;
        input.readLength();
      }
      // Each entry takes at least two bytes: the lengths of its key and its value.
      if (count > input.remaining ~/ 2) {
        input.fail('declares $count metadata entries, more than fit', start);
      }
      for (var i = 0; i < count; i++) {
        final key = input.readString();
        metadata[key] = input.readBytes();
      }
    }
    final syncMarker = input.readFixed(16);
    final rawSchema = metadata['avro.schema'];
    if (rawSchema == null) {
      throw const DecodeException('the metadata has no avro.schema', offset: 4);
    }
    final String schemaJson;
    final String compression;
    try {
      schemaJson = const Utf8Decoder().convert(rawSchema);
      compression = switch (metadata['avro.codec']) {
        null => 'null',
        final v => const Utf8Decoder().convert(v),
      };
    } on FormatException {
      throw const DecodeException(
        'avro.schema or avro.codec is not UTF-8',
        offset: 4,
      );
    }
    if (!supportedCompressions.contains(compression)) {
      throw UnsupportedCompressionException(
        'blocks compressed with "$compression" cannot be read; only null and deflate',
        compression: compression,
      );
    }
    header = AvroFileHeader._(metadata, schemaJson, compression, syncMarker);
    _blocksStart = input.offset;
  }

  final Uint8List _bytes;
  late final int _blocksStart;

  /// The limits on the blocks and on the schema of the file.
  final AvroLimits limits;

  /// The file's header.
  late final AvroFileHeader header;

  /// The records of the file, decoded lazily, one block at a time, with [codec], or with a
  /// codec of the file's own schema when [codec] is null.
  ///
  /// Iterating throws [DecodeException] for a malformed block, and [LimitExceededException]
  /// as soon as a block's decompressed size or the total exceeds [limits].
  Iterable<Object?> records([AvroCodec? codec]) sync* {
    final c =
        codec ??
        AvroCodec(
          writer: Schema.parse(header.schemaJson, limits: limits),
          limits: limits,
        );
    final input = BinaryReader(_bytes, _blocksStart);
    var total = 0;
    while (input.remaining > 0) {
      final start = input.offset;
      final count = input.readLong();
      if (count < 0) input.fail('a block cannot hold $count records', start);
      final size = input.readLength();
      final dataStart = input.offset;
      final data = Uint8List.sublistView(_bytes, dataStart, dataStart + size);
      input.skip(size);
      final sync = input.readFixed(16);
      for (var i = 0; i < 16; i++) {
        if (sync[i] != header.syncMarker[i]) {
          input.fail(
            'the sync marker after the block does not match',
            input.offset - 16,
          );
        }
      }
      final block = header.compression == 'deflate'
          ? _inflate(data, total, dataStart)
          : _checkSize(data, total);
      total += block.length;
      final blockInput = BinaryReader(block);
      final min = minEncodedSize(c.writer);
      if (min > 0
          ? count > block.length ~/ min
          : count > (limits.maxZeroSizeItems ?? count)) {
        input.fail(
          'the block declares $count records, more than it can hold',
          start,
        );
      }
      for (var i = 0; i < count; i++) {
        yield decodeFrom(c, blockInput);
      }
      if (blockInput.remaining != 0) {
        input.fail(
          'the block has ${blockInput.remaining} bytes left after its $count records',
          start,
        );
      }
    }
  }

  Uint8List _checkSize(Uint8List block, int total) {
    final maxBlock = limits.maxBlockBytes;
    if (maxBlock != null && block.length > maxBlock) {
      throw LimitExceededException(
        'a block has ${block.length} bytes, the limit is $maxBlock',
        limit: 'maxBlockBytes',
      );
    }
    final maxTotal = limits.maxTotalBytes;
    if (maxTotal != null && total + block.length > maxTotal) {
      throw LimitExceededException(
        'the blocks exceed $maxTotal bytes',
        limit: 'maxTotalBytes',
      );
    }
    return block;
  }

  /// Raw DEFLATE, stopped as soon as the output exceeds a limit.
  Uint8List _inflate(Uint8List data, int total, int offset) {
    final out = _LimitedSink(this, total);
    final sink = ZLibDecoder(raw: true).startChunkedConversion(out);
    try {
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
    } on LimitExceededException {
      rethrow;
    } on Exception catch (e) {
      throw DecodeException(
        'the block is not valid DEFLATE: $e',
        offset: offset,
      );
    }
    return out.bytes.takeBytes();
  }
}

final class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this.reader, this.total);

  final AvroFileReader reader;
  final int total;
  final BytesBuilder bytes = BytesBuilder(copy: true);

  @override
  void add(List<int> chunk) {
    bytes.add(chunk);
    final limits = reader.limits;
    final maxBlock = limits.maxBlockBytes;
    if (maxBlock != null && bytes.length > maxBlock) {
      throw LimitExceededException(
        'a block inflates beyond $maxBlock bytes',
        limit: 'maxBlockBytes',
      );
    }
    final maxTotal = limits.maxTotalBytes;
    if (maxTotal != null && total + bytes.length > maxTotal) {
      throw LimitExceededException(
        'the blocks inflate beyond $maxTotal bytes',
        limit: 'maxTotalBytes',
      );
    }
  }

  @override
  void close() {}
}
