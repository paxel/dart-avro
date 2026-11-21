import 'dart:convert';
import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show
        ArchiveLimitException,
        BZip2Decoder,
        BZip2Encoder,
        InputMemoryStream,
        OutputMemoryStream,
        XZDecoder,
        XZEncoder,
        xzDefaultMaxPreallocateSize,
        ZstdDecoder,
        ZstdEncoder;

import 'binary.dart';
import 'codec.dart';
import 'exceptions.dart';
import 'fingerprint.dart';
import 'limits.dart';
import 'schema.dart';
import 'snappy.dart';

/// The magic at the start of every object container file: `Obj` and the byte 1.
const containerMagic = [0x4f, 0x62, 0x6a, 0x01];

/// The compressions this package reads and writes.
const supportedCompressions = {
  'null',
  'deflate',
  'snappy',
  'bzip2',
  'xz',
  'zstandard',
};

/// The [supportedCompressions] in words, for messages.
String get _supportedNames {
  final names = supportedCompressions.toList();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

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

  /// How the blocks are compressed, the file's `avro.codec`:
  /// `null`, `deflate`, `snappy`, `bzip2`, `xz` or `zstandard`.
  final String compression;

  /// The 16 bytes that end every block.
  final Uint8List syncMarker;
}

/// Reads an object container file held in memory.
///
/// The constructor reads the header only. Throws [DecodeException] if it is not a container
/// file, and [UnsupportedCompressionException] if its blocks use a compression other than
/// `null`, `deflate`, `snappy`, `bzip2`, `xz` and `zstandard`.
final class AvroFileReader {
  AvroFileReader(Uint8List bytes, {this.limits = const AvroLimits()})
    : _bytes = bytes {
    final (header, blocksStart) = HeaderParser().parse(bytes);
    this.header = header;
    _blocksStart = blocksStart;
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
    final blocks = BlockDecoder(
      header.compression,
      limits,
      recordCodec(header, limits, codec),
    );
    final input = BinaryReader(_bytes, _blocksStart);
    while (input.remaining > 0) {
      final start = input.offset;
      final (:count, :dataStart, :size) = readBlockFrame(
        input,
        header.syncMarker,
      );
      yield* blocks.decode(
        count,
        Uint8List.sublistView(_bytes, dataStart, dataStart + size),
        start,
        dataStart,
      );
    }
  }
}

/// Reads the header of a container file, also from the start of a file that is still
/// arriving: after an [InputUnderflow] from a partial input, [parse] can be called again
/// with more of the same bytes and resumes after the last complete metadata entry.
final class HeaderParser {
  final _metadata = <String, Uint8List>{};
  var _offset = 0;
  var _magicRead = false;
  var _entriesLeft = 0;

  /// The header at the start of [bytes], up to [end], and the offset of the first block.
  (AvroFileHeader, int) parse(
    Uint8List bytes, {
    int? end,
    bool partial = false,
  }) {
    final input = BinaryReader(bytes, _offset, end, partial);
    if (!_magicRead) {
      const notAFile =
          'not an Avro container file: the magic "Obj" 1 is missing';
      for (final b in containerMagic) {
        if (input.remaining == 0) input.short(1, notAFile, 0);
        if (input.readByte() != b) {
          throw const DecodeException(notAFile, offset: 0);
        }
      }
      _magicRead = true;
      _offset = input.offset;
    }
    while (true) {
      if (_entriesLeft == 0) {
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
          input.short(
            count > 1 << 52 ? 1 << 53 : count * 2,
            'declares $count metadata entries, more than fit',
            start,
          );
        }
        _entriesLeft = count;
        _offset = input.offset;
      }
      final key = input.readString();
      _metadata[key] = input.readBytes();
      _entriesLeft--;
      _offset = input.offset;
    }
    final syncMarker = input.readFixed(16);
    final rawSchema = _metadata['avro.schema'];
    if (rawSchema == null) {
      throw const DecodeException('the metadata has no avro.schema', offset: 4);
    }
    final String schemaJson;
    final String compression;
    try {
      schemaJson = const Utf8Decoder().convert(rawSchema);
      compression = switch (_metadata['avro.codec']) {
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
        'blocks compressed with "$compression" cannot be read; only $_supportedNames',
        compression: compression,
      );
    }
    final header = AvroFileHeader._(
      _metadata,
      schemaJson,
      compression,
      syncMarker,
    );
    return (header, input.offset);
  }
}

/// The codec that decodes the records of a file with [header]: [codec], or one of the
/// file's schema when [codec] is null. Throws [DecodeException] if [codec]'s writer schema
/// is not the file's.
AvroCodec recordCodec(
  AvroFileHeader header,
  AvroLimits limits,
  AvroCodec? codec,
) {
  final fileSchema = Schema.parse(header.schemaJson, limits: limits);
  if (codec != null && codec.writer.canonicalForm != fileSchema.canonicalForm) {
    throw DecodeException(
      'the codec writes the schema ${_hex(codec.writer.crc64)}, '
      'but the file was written with ${_hex(fileSchema.crc64)}; '
      "make the file's schema the codec's writer and yours its reader",
      offset: 0,
    );
  }
  return codec ?? AvroCodec(writer: fileSchema, limits: limits);
}

/// Reads the frame of the block at [input]'s offset, up to and including its sync marker,
/// which must be [syncMarker]: its record count, and where its data starts and how long it
/// is. [checkSize] sees the declared size of the data before it is compared with the input.
({int count, int dataStart, int size}) readBlockFrame(
  BinaryReader input,
  Uint8List syncMarker, [
  void Function(int size)? checkSize,
]) {
  final start = input.offset;
  final count = input.readLong();
  if (count < 0) input.fail('a block cannot hold $count records', start);
  final size = input.readLength(checkSize);
  final dataStart = input.offset;
  input.skip(size);
  final sync = input.readFixed(16);
  for (var i = 0; i < 16; i++) {
    if (sync[i] != syncMarker[i]) {
      input.fail(
        'the sync marker after the block does not match',
        input.offset - 16,
      );
    }
  }
  return (count: count, dataStart: dataStart, size: size);
}

/// Decompresses and decodes the blocks of one file, in order, within [limits].
final class BlockDecoder {
  BlockDecoder(this.compression, this.limits, this.codec);

  final String compression;
  final AvroLimits limits;
  final AvroCodec codec;
  int _total = 0;

  /// The [count] records of the block whose frame starts at the file offset [start] and
  /// whose [data] starts at the file offset [dataStart], decoded lazily.
  Iterable<Object?> decode(
    int count,
    Uint8List data,
    int start,
    int dataStart,
  ) sync* {
    final block = switch (compression) {
      'deflate' => _inflate(limits, data, _total, dataStart),
      'snappy' => _unsnappy(limits, data, _total, dataStart),
      'bzip2' ||
      'xz' ||
      'zstandard' => _unarchive(compression, limits, data, _total, dataStart),
      _ => _checkSize(limits, data, _total),
    };
    _total += block.length;
    final blockInput = BinaryReader(block);
    final min = minEncodedSize(codec.writer);
    if (min > 0) {
      if (count > block.length ~/ min) {
        throw DecodeException(
          'the block declares $count records, more than it can hold',
          offset: start,
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
      final Object? record;
      try {
        record = decodeFrom(codec, blockInput);
      } on DecodeException catch (e) {
        throw DecodeException(
          e.message,
          offset: e.offset,
          path: e.path,
          blockOffset: start,
        );
      }
      yield record;
    }
    if (blockInput.remaining != 0) {
      throw DecodeException(
        'the block has ${blockInput.remaining} bytes left after its $count records',
        offset: start,
      );
    }
  }
}

Uint8List _checkSize(AvroLimits limits, Uint8List block, int total) {
  _checkLength(limits, block.length, total);
  return block;
}

/// Throws if a block of [length] bytes after [total] bytes exceeds the limits.
void _checkLength(AvroLimits limits, int length, int total) {
  final maxBlock = limits.maxBlockBytes;
  if (maxBlock != null && length > maxBlock) {
    throw LimitExceededException(
      'a block has $length bytes, the limit is $maxBlock',
      limit: 'maxBlockBytes',
    );
  }
  final maxTotal = limits.maxTotalBytes;
  if (maxTotal != null && total + length > maxTotal) {
    throw LimitExceededException(
      'the blocks exceed $maxTotal bytes',
      limit: 'maxTotalBytes',
    );
  }
}

/// `bzip2`, `xz` or `zstandard` through `archive`, with its checksums verified, stopped
/// as soon as the output exceeds the block limit or what is left of the total limit.
Uint8List _unarchive(
  String compression,
  AvroLimits limits,
  Uint8List data,
  int total,
  int offset,
) {
  final maxBlock = limits.maxBlockBytes;
  final maxTotal = limits.maxTotalBytes;
  final left = maxTotal == null ? null : maxTotal - total;
  final blockBinds = maxBlock != null && (left == null || maxBlock <= left);
  final max = blockBinds ? maxBlock : left;
  final input = InputMemoryStream(data);
  final output = OutputMemoryStream();
  try {
    final ok = switch (compression) {
      'bzip2' => BZip2Decoder().decodeStream(
        input,
        output,
        verify: true,
        throwOnError: true,
        maxOutputSize: max,
      ),
      'xz' =>
        XZDecoder(
          maxPreallocateSize: max == null || max > xzDefaultMaxPreallocateSize
              ? null
              : max,
        ).decodeStream(
          input,
          output,
          verify: true,
          throwOnError: true,
          maxOutputSize: max,
        ),
      _ => ZstdDecoder().decodeStream(
        input,
        output,
        verify: true,
        throwOnError: true,
        maxOutputSize: max,
      ),
    };
    if (!ok) {
      throw DecodeException(
        'the block is not valid $compression',
        offset: offset,
      );
    }
  } on ArchiveLimitException catch (e) {
    // archive's own caps, such as a zstandard window over 128 MiB, are not ours.
    if (max == null || !e.message.startsWith('The decoded data is larger')) {
      throw DecodeException(
        'the block needs more memory than the $compression decoder allows: ${e.message}',
        offset: offset,
      );
    }
    throw blockBinds
        ? LimitExceededException(
            'a block decompresses beyond $max bytes',
            limit: 'maxBlockBytes',
          )
        : LimitExceededException(
            'the blocks decompress beyond $maxTotal bytes',
            limit: 'maxTotalBytes',
          );
  } on FormatException catch (e) {
    throw DecodeException(
      'the block is not valid $compression: ${e.message}',
      offset: offset,
    );
  }
  return output.getBytes();
}

/// Snappy, followed by the big-endian CRC32 of the uncompressed block. The declared
/// length is checked against the limits before the block is allocated.
Uint8List _unsnappy(AvroLimits limits, Uint8List data, int total, int offset) {
  if (data.length < 4) {
    throw DecodeException(
      'a snappy block has ${data.length} bytes, too few for its CRC32',
      offset: offset,
    );
  }
  final crcAt = data.length - 4;
  final block = snappyDecompress(
    Uint8List.sublistView(data, 0, crcAt),
    (length) => _checkLength(limits, length, total),
    offset,
  );
  if (crc32(block) != ByteData.sublistView(data, crcAt).getUint32(0)) {
    throw DecodeException(
      'the CRC32 after the snappy block does not match its data',
      offset: offset + crcAt,
    );
  }
  return block;
}

/// Raw DEFLATE, stopped as soon as the output exceeds a limit.
Uint8List _inflate(AvroLimits limits, Uint8List data, int total, int offset) {
  final out = _LimitedSink(limits, total);
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
    throw DecodeException('the block is not valid DEFLATE: $e', offset: offset);
  }
  return out.bytes.takeBytes();
}

String _hex(int fingerprint) =>
    '0x${BigInt.from(fingerprint).toUnsigned(64).toRadixString(16).padLeft(16, '0')}';

final class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this.limits, this.total);

  final AvroLimits limits;
  final int total;
  final BytesBuilder bytes = BytesBuilder(copy: true);

  @override
  void add(List<int> chunk) {
    bytes.add(chunk);
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
  /// bytes. Throws [UnsupportedCompressionException] for a [compression] other than
  /// `null`, `deflate`, `snappy`, `bzip2`, `xz` and `zstandard`. `xz` blocks are stored in
  /// the format without being compressed, as `archive` writes them.
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
        'blocks cannot be compressed with "$compression"; only $_supportedNames',
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

  /// `null`, `deflate`, `snappy`, `bzip2`, `xz` or `zstandard`.
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
    final data = switch (compression) {
      'deflate' => ZLibEncoder(raw: true).convert(raw),
      'snappy' => _snappy(raw),
      'bzip2' => BZip2Encoder().encodeBytes(raw),
      'xz' => XZEncoder().encodeBytes(raw),
      // With the frame's checksum, so that a damaged block cannot read as other records.
      'zstandard' => ZstdEncoder().encodeBytes(raw, checksum: true),
      _ => raw,
    };
    _out
      ..writeLong(_count)
      ..writeBytes(data)
      ..writeFixed(syncMarker);
    _block = BinaryWriter();
    _count = 0;
  }

  /// Snappy, followed by the big-endian CRC32 of [raw].
  static Uint8List _snappy(Uint8List raw) {
    final compressed = snappyCompress(raw);
    final data = Uint8List(compressed.length + 4)..setAll(0, compressed);
    ByteData.sublistView(data).setUint32(compressed.length, crc32(raw));
    return data;
  }

  /// Ends the last block and returns the whole file. The writer cannot be used after.
  Uint8List close() {
    flush();
    _closed = true;
    return _out.toBytes();
  }
}
