import 'dart:convert';
import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:math';
import 'dart:typed_data';

import 'binary.dart';
import 'codec.dart';
import 'exceptions.dart';
import 'fingerprint.dart';
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
  /// [codec]'s writer schema must have the canonical form of the file's schema; iterating
  /// throws [DecodeException] before the first record if it has not. To read the records as
  /// another schema, pass a codec whose writer is the file's schema and whose reader is yours.
  ///
  /// Iterating throws [DecodeException] for a malformed block, and [LimitExceededException]
  /// as soon as a block's decompressed size or the total exceeds [limits].
  Iterable<Object?> records([AvroCodec? codec]) sync* {
    final fileSchema = Schema.parse(header.schemaJson, limits: limits);
    if (codec != null &&
        codec.writer.canonicalForm != fileSchema.canonicalForm) {
      throw DecodeException(
        'the codec writes the schema ${_hex(codec.writer.crc64)}, '
        'but the file was written with ${_hex(fileSchema.crc64)}; '
        "make the file's schema the codec's writer and yours its reader",
        offset: 0,
      );
    }
    final c = codec ?? AvroCodec(writer: fileSchema, limits: limits);
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
      if (min > 0) {
        if (count > block.length ~/ min) {
          input.fail(
            'the block declares $count records, more than it can hold',
            start,
          );
        }
      } else {
        final max = limits.maxZeroSizeItems;
        if (max != null && count > max) {
          throw LimitExceededException(
            'a block declares $count records of zero bytes, the limit is $max',
            limit: 'maxZeroSizeItems',
          );
        }
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

String _hex(int fingerprint) =>
    '0x${BigInt.from(fingerprint).toUnsigned(64).toRadixString(16).padLeft(16, '0')}';

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

/// Writes an object container file in memory.
///
/// Records are added with [add]; a block ends when it reaches [blockSize] bytes before
/// compression, or at [flush]. [close] ends the last block and returns the file.
final class AvroFileWriter {
  /// A writer of records encoded with [codec]'s writer schema.
  ///
  /// [metadata] is written first, in its order, then `avro.codec` (always) and
  /// `avro.schema`; a key starting with `avro.` is reserved and throws [ArgumentError].
  /// [schemaJson] is written exactly as given and defaults to the writer schema's text; it
  /// must have the writer schema's canonical form. [syncMarker] defaults to 16 random
  /// bytes. Throws [UnsupportedCompressionException] for a [compression] other than `null`
  /// and `deflate`.
  AvroFileWriter(
    this.codec, {
    this.compression = 'null',
    Map<String, Uint8List> metadata = const {},
    Uint8List? syncMarker,
    String? schemaJson,
    this.blockSize = 64 * 1024,
  }) : syncMarker = syncMarker ?? _randomSync() {
    if (!supportedCompressions.contains(compression)) {
      throw UnsupportedCompressionException(
        'blocks cannot be compressed with "$compression"; only null and deflate',
        compression: compression,
      );
    }
    if (this.syncMarker.length != 16) {
      throw ArgumentError.value(syncMarker, 'syncMarker', 'must be 16 bytes');
    }
    final text = schemaJson ?? codec.writer.jsonText;
    if (schemaJson != null &&
        Schema.parse(schemaJson, limits: codec.limits).canonicalForm !=
            codec.writer.canonicalForm) {
      throw ArgumentError.value(
        schemaJson,
        'schemaJson',
        "does not have the codec's writer schema",
      );
    }
    for (final key in metadata.keys) {
      if (key.startsWith('avro.')) {
        throw ArgumentError.value(
          key,
          'metadata',
          'keys starting with avro. are reserved',
        );
      }
    }
    final header = BinaryWriter()..writeFixed(containerMagic);
    final entries = {
      ...metadata,
      'avro.codec': Uint8List.fromList(utf8.encode(compression)),
      'avro.schema': Uint8List.fromList(utf8.encode(text)),
    };
    header.writeLong(entries.length);
    for (final e in entries.entries) {
      header
        ..writeString(e.key)
        ..writeBytes(e.value);
    }
    header
      ..writeLong(0)
      ..writeFixed(this.syncMarker);
    _out.writeFixed(header.toBytes());
  }

  static Uint8List _randomSync() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  }

  /// The codec the records are encoded with.
  final AvroCodec codec;

  /// `null` or `deflate`.
  final String compression;

  /// The 16 bytes that end every block.
  final Uint8List syncMarker;

  /// The size in bytes, before compression, at which a block ends by itself.
  final int blockSize;

  final BinaryWriter _out = BinaryWriter();
  BinaryWriter _block = BinaryWriter();
  int _count = 0;
  bool _closed = false;

  /// Adds one record. Throws [EncodeException] if it does not fit the writer schema; the
  /// file is unchanged then.
  void add(Object? record) {
    if (_closed) throw StateError('the writer is closed');
    final datum = codec.encode(record);
    _block.writeFixed(datum);
    _count++;
    if (_block.length >= blockSize) flush();
  }

  /// Ends the current block, if it holds any record.
  void flush() {
    if (_closed) throw StateError('the writer is closed');
    if (_count == 0) return;
    final raw = _block.toBytes();
    final data = compression == 'deflate'
        ? ZLibEncoder(raw: true).convert(raw)
        : raw;
    _out
      ..writeLong(_count)
      ..writeBytes(data)
      ..writeFixed(syncMarker);
    _block = BinaryWriter();
    _count = 0;
  }

  /// Ends the last block and returns the whole file. The writer cannot be used after.
  Uint8List close() {
    flush();
    _closed = true;
    return _out.toBytes();
  }
}
