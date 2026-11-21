import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'binary.dart';
import 'codec.dart';
import 'container.dart';
import 'exceptions.dart';
import 'limits.dart';

/// Reads an object container file from a stream of bytes, one block at a time.
///
/// [open] reads the header; [records] decodes the blocks after it as they arrive. The
/// records, the errors and their offsets are those of `AvroFileReader` for the same bytes,
/// except that a block declaring more compressed bytes than `maxBlockBytes` throws
/// [LimitExceededException] before it is read, and that a header longer than `maxBlockBytes`
/// throws [LimitExceededException] as well.
final class AvroFileStreamReader {
  AvroFileStreamReader._(this._input, this.limits, this.header);

  /// Reads the header from [input] and completes with a reader of the blocks after it.
  ///
  /// Completes with [DecodeException] if [input] is not a container file, and with
  /// [UnsupportedCompressionException] if its blocks use a compression other than `null`,
  /// `deflate`, `snappy`, `bzip2`, `xz` and `zstandard`; the subscription to [input] is
  /// cancelled then. Completes with [LimitExceededException] as soon as the header needs more
  /// than `maxBlockBytes` of [limits]. An error of [input] itself is passed on as it is.
  static Future<AvroFileStreamReader> open(
    Stream<List<int>> input, {
    AvroLimits limits = const AvroLimits(),
  }) async {
    final bytes = _Input(StreamIterator(input));
    try {
      final parser = HeaderParser();
      while (true) {
        try {
          // The header is read before anything is consumed, so its offsets are the file's.
          final (header, end) = parser.parse(
            bytes.bytes,
            end: bytes.end,
            partial: !bytes.done,
          );
          _checkHeaderSize(limits, end);
          bytes.start = end;
          return AvroFileStreamReader._(bytes, limits, header);
        } on InputUnderflow catch (e) {
          // Fails before the bytes are buffered.
          _checkHeaderSize(limits, e.end);
          await bytes.fill(e.end);
        }
      }
    } on Object {
      await bytes.cancel();
      rethrow;
    }
  }

  static void _checkHeaderSize(AvroLimits limits, int size) {
    final max = limits.maxBlockBytes;
    if (max != null && size > max) {
      throw LimitExceededException(
        'the header needs more than $max bytes',
        limit: 'maxBlockBytes',
      );
    }
  }

  final _Input _input;
  bool _read = false;

  /// The limits on the blocks and on the schema of the file.
  final AvroLimits limits;

  /// The file's header.
  final AvroFileHeader header;

  /// The records of the file, decoded with [codec], or with a codec of the file's own
  /// schema when [codec] is null. Only one block is held in memory at a time.
  ///
  /// [codec]'s writer schema must have the canonical form of the file's schema; the stream
  /// has a [DecodeException] before the first record if it has not. To read the records as
  /// another schema, pass a codec whose writer is the file's schema and whose reader is yours.
  ///
  /// The stream ends with a [DecodeException] for a malformed or cut-off block, and with a
  /// [LimitExceededException] as soon as a block's compressed or decompressed size or the
  /// total exceeds [limits]. Throws [StateError] if called a second time or after [cancel].
  Stream<Object?> records([AvroCodec? codec]) {
    if (_input.cancelled) throw StateError('the reader is cancelled');
    if (_read) throw StateError('the records can be read only once');
    _read = true;
    return _records(codec);
  }

  Stream<Object?> _records(AvroCodec? codec) async* {
    final input = _input;
    try {
      final blocks = BlockDecoder(
        header.compression,
        limits,
        recordCodec(header, limits, codec),
      );
      while (!input.cancelled) {
        if (input.start == input.end) {
          if (input.done) break;
          await input.fill(input.base + input.end + 1);
          continue;
        }
        final frame = await _frame();
        if (frame == null) break;
        final (count, data, start, dataStart) = frame;
        for (final record in blocks.decode(count, data, start, dataStart)) {
          if (input.cancelled) return;
          yield record;
        }
      }
    } finally {
      await input.cancel();
    }
  }

  /// The next block's frame, with its data and the file offsets of its start and data, or
  /// null if the reader was cancelled while waiting for it.
  Future<(int, Uint8List, int, int)?> _frame() async {
    final input = _input;
    while (!input.cancelled) {
      final reader = BinaryReader(
        input.bytes,
        input.start,
        input.end,
        !input.done,
      );
      try {
        final (:count, :dataStart, :size) = readBlockFrame(
          reader,
          header.syncMarker,
          _checkCompressedSize,
        );
        final frame = (
          count,
          Uint8List.sublistView(input.bytes, dataStart, dataStart + size),
          input.base + input.start,
          input.base + dataStart,
        );
        input.start = reader.offset;
        return frame;
      } on InputUnderflow catch (e) {
        await input.fill(input.base + e.end);
      } on DecodeException catch (e) {
        throw DecodeException(
          e.message,
          offset: input.base + e.offset,
          path: e.path,
          blockOffset: e.blockOffset,
        );
      }
    }
    return null;
  }

  /// Cancels the subscription to the input. A stream of [records] that is running ends,
  /// without an error; [records] cannot be called after.
  Future<void> cancel() => _input.cancel();

  /// Fails before a block's data is buffered if it is larger than the block limit.
  void _checkCompressedSize(int size) {
    final max = limits.maxBlockBytes;
    if (max != null && size > max) {
      throw LimitExceededException(
        'a block declares $size compressed bytes, the limit is $max',
        limit: 'maxBlockBytes',
      );
    }
  }
}

/// The bytes of a stream that have arrived and are not yet consumed.
final class _Input {
  _Input(this._source);

  final StreamIterator<List<int>> _source;

  /// The buffer; the bytes from [start] to [end] are not yet consumed.
  Uint8List bytes = Uint8List(0);

  /// The file offset of `bytes[0]`.
  int base = 0;
  int start = 0;
  int end = 0;

  /// Whether the stream has ended.
  bool done = false;

  /// Whether the subscription is cancelled.
  bool cancelled = false;

  /// Reads chunks until the bytes reach the file offset [fileEnd] or the stream ends.
  Future<void> fill(int fileEnd) async {
    while (!done && base + end < fileEnd) {
      if (await _source.moveNext()) {
        _append(_source.current);
      } else {
        done = true;
      }
    }
  }

  void _append(List<int> chunk) {
    if (end + chunk.length > bytes.length) {
      // A new buffer, so that the data of a block already returned stays as it is.
      final pending = end - start;
      final grown = Uint8List(max(2 * (pending + chunk.length), 4096))
        ..setRange(0, pending, bytes, start);
      bytes = grown;
      base += start;
      start = 0;
      end = pending;
    }
    bytes.setRange(end, end + chunk.length, chunk);
    end += chunk.length;
  }

  Future<void> cancel() async {
    if (cancelled) return;
    cancelled = true;
    done = true;
    await _source.cancel();
  }
}

/// Writes an object container file to a stream sink, one block at a time.
///
/// The header is written to the sink at once. Records are added with [add]; a block is
/// written when it reaches [blockSize] bytes before compression, or at [flush]. [close]
/// writes the last block and closes the sink. The bytes are those `AvroFileWriter` returns
/// for the same records, flushes and [syncMarker].
final class AvroFileStreamWriter {
  /// A writer of records encoded with [codec]'s writer schema to [sink].
  ///
  /// [metadata] is written first, in its order, then `avro.codec` (always) and
  /// `avro.schema`; a key starting with `avro.` is reserved and throws [ArgumentError].
  /// [schemaJson] is written exactly as given and defaults to the writer schema's text; it
  /// must have the writer schema's canonical form. [syncMarker] defaults to 16 random
  /// bytes. Throws [UnsupportedCompressionException] for a [compression] other than
  /// `null`, `deflate`, `snappy`, `bzip2`, `xz` and `zstandard`; nothing is written to
  /// [sink] then. `xz` blocks are stored in the format without being compressed, as
  /// `archive` writes them.
  AvroFileStreamWriter(
    this.codec,
    StreamSink<List<int>> sink, {
    this.compression = 'null',
    Map<String, Uint8List> metadata = const {},
    Uint8List? syncMarker,
    String? schemaJson,
    this.blockSize = 64 * 1024,
  }) : _sink = sink,
       syncMarker = syncMarker ?? randomSyncMarker() {
    final header = encodeHeader(
      codec,
      compression,
      metadata,
      this.syncMarker,
      schemaJson,
    );
    _blocks = BlockEncoder(codec, compression, this.syncMarker, blockSize);
    _sink.add(header);
  }

  final StreamSink<List<int>> _sink;
  late final BlockEncoder _blocks;
  bool _closed = false;

  /// The codec the records are encoded with.
  final AvroCodec codec;

  /// `null`, `deflate`, `snappy`, `bzip2`, `xz` or `zstandard`.
  final String compression;

  /// The 16 bytes that end every block.
  final Uint8List syncMarker;

  /// The size in bytes, before compression, at which a block ends by itself.
  final int blockSize;

  /// Adds one record, and writes the block if it has reached [blockSize]. Throws
  /// [EncodeException] if the record does not fit the writer schema; nothing is written
  /// and the block is unchanged then. Throws [StateError] after [close].
  void add(Object? record) {
    if (_closed) throw StateError('the writer is closed');
    if (_blocks.add(record)) flush();
  }

  /// Writes the current block, if it holds any record. Throws [StateError] after [close].
  void flush() {
    if (_closed) throw StateError('the writer is closed');
    final block = _blocks.take();
    if (block != null) _sink.add(block);
  }

  /// Writes the last block and closes the sink; completes when the sink is closed. The
  /// writer cannot be used after; a second call throws [StateError].
  Future<void> close() {
    flush();
    _closed = true;
    return _sink.close();
  }
}
