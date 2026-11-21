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
/// [LimitExceededException] before it is read.
final class AvroFileStreamReader {
  AvroFileStreamReader._(this._input, this.limits, this.header);

  /// Reads the header from [input] and completes with a reader of the blocks after it.
  ///
  /// Completes with [DecodeException] if [input] is not a container file, and with
  /// [UnsupportedCompressionException] if its blocks use a compression other than `null`,
  /// `deflate`, `snappy`, `bzip2`, `xz` and `zstandard`; the subscription to [input] is
  /// cancelled then. An error of [input] itself is passed on as it is.
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
          bytes.start = end;
          return AvroFileStreamReader._(bytes, limits, header);
        } on InputUnderflow catch (e) {
          await bytes.fill(e.end);
        }
      }
    } on Object {
      await bytes.cancel();
      rethrow;
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
  /// total exceeds [limits]. Throws [StateError] if called a second time.
  Stream<Object?> records([AvroCodec? codec]) {
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
      while (true) {
        if (input.start == input.end) {
          if (input.done) break;
          await input.fill(input.base + input.end + 1);
          continue;
        }
        final (count, data, start, dataStart) = await _frame();
        for (final record in blocks.decode(count, data, start, dataStart)) {
          yield record;
        }
      }
    } finally {
      await input.cancel();
    }
  }

  /// The next block's frame, with its data and the file offsets of its start and data.
  Future<(int, Uint8List, int, int)> _frame() async {
    final input = _input;
    while (true) {
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
  }

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
    done = true;
    await _source.cancel();
  }
}
