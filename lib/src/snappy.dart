// Snappy in its raw format, as Avro's `snappy` compression uses it for each block: the
// uncompressed length as a varint, then literal and copy elements
// (https://github.com/google/snappy/blob/main/format_description.txt). And the CRC32 that
// Avro appends to each Snappy block.

import 'dart:typed_data';

import 'exceptions.dart';

/// The most uncompressed bytes one compressed byte can stand for, rounded up: a copy with a
/// 2-byte offset takes 3 bytes and repeats up to 64.
const _maxExpansion = 22;

/// The Snappy compressed bytes of [input], in one piece.
///
/// A greedy matcher over a hash table of 4-byte sequences; copies reach at most 65535 bytes
/// back, so a block larger than 64 KiB is compressed correctly, if a little less well.
Uint8List snappyCompress(Uint8List input) {
  final n = input.length;
  // Snappy's own bound on the compressed size.
  final out = Uint8List(32 + n + n ~/ 6);
  var o = 0;

  var v = n;
  while (v >= 0x80) {
    out[o++] = (v & 0x7f) | 0x80;
    v >>= 7;
  }
  out[o++] = v;

  void literal(int start, int end) {
    final length = end - start;
    if (length == 0) return;
    final l = length - 1;
    if (l < 60) {
      out[o++] = l << 2;
    } else {
      final bytes = l < 0x100
          ? 1
          : l < 0x10000
          ? 2
          : l < 0x1000000
          ? 3
          : 4;
      out[o++] = (59 + bytes) << 2;
      for (var k = 0; k < bytes; k++) {
        out[o++] = (l >> (8 * k)) & 0xff;
      }
    }
    out.setRange(o, o + length, input, start);
    o += length;
  }

  void copy(int offset, int length) {
    if (length <= 11 && offset < 2048) {
      out[o++] = 1 | ((length - 4) << 2) | ((offset >> 8) << 5);
      out[o++] = offset & 0xff;
    } else {
      out[o++] = 2 | ((length - 1) << 2);
      out[o++] = offset & 0xff;
      out[o++] = offset >> 8;
    }
  }

  int load32(int at) =>
      input[at] |
      (input[at + 1] << 8) |
      (input[at + 2] << 16) |
      (input[at + 3] << 24);

  // Positions plus one, so that 0 means no entry.
  final table = Int32List(1 << 14);
  var literalStart = 0;
  var i = 0;
  while (i + 4 <= n) {
    final key = load32(i);
    final h = ((key * 0x1e35a7bd) & 0xffffffff) >> 18;
    final candidate = table[h] - 1;
    table[h] = i + 1;
    if (candidate < 0 || i - candidate > 0xffff || load32(candidate) != key) {
      i++;
      continue;
    }
    literal(literalStart, i);
    var length = 4;
    while (i + length < n && input[candidate + length] == input[i + length]) {
      length++;
    }
    final offset = i - candidate;
    i += length;
    literalStart = i;
    // Pieces of at most 64 bytes, none shorter than 4.
    while (length >= 68) {
      copy(offset, 64);
      length -= 64;
    }
    if (length > 64) {
      copy(offset, 60);
      length -= 60;
    }
    copy(offset, length);
  }
  literal(literalStart, n);
  return Uint8List.sublistView(out, 0, o);
}

/// The uncompressed bytes of the Snappy compressed [input].
///
/// [checkLength] is called with the declared uncompressed length before anything is
/// allocated, so that it can throw. Throws [DecodeException], with offsets counted from
/// [offset], for input that is not valid Snappy, including a declared length that [input]
/// cannot hold and elements that reach beyond the declared length.
Uint8List snappyDecompress(
  Uint8List input,
  void Function(int length) checkLength, [
  int offset = 0,
]) {
  Never fail(String message, int at) => throw DecodeException(
    'the block is not valid Snappy: $message',
    offset: offset + at,
  );

  var i = 0;
  var length = 0;
  for (var shift = 0; ; shift += 7) {
    if (i == input.length) fail('the uncompressed length is cut off', 0);
    final b = input[i++];
    if (shift == 28 && b > 0x0f) {
      fail('the uncompressed length does not fit 32 bits', 0);
    }
    length |= (b & 0x7f) << shift;
    if (b < 0x80) break;
  }
  checkLength(length);
  if (length > (input.length - i) * _maxExpansion) {
    fail(
      'it declares $length bytes, more than its ${input.length - i} bytes can hold',
      0,
    );
  }

  final out = Uint8List(length);
  var o = 0;
  while (i < input.length) {
    final start = i;
    final tag = input[i++];
    final int size;
    final int distance;
    int read(int bytes) {
      if (bytes > input.length - i) fail('an element is cut off', start);
      var v = 0;
      for (var k = 0; k < bytes; k++) {
        v |= input[i++] << (8 * k);
      }
      return v;
    }

    switch (tag & 3) {
      case 0:
        var l = tag >> 2;
        if (l >= 60) l = read(l - 59);
        final literalLength = l + 1;
        if (literalLength > input.length - i) {
          fail('a literal of $literalLength bytes is cut off', start);
        }
        if (literalLength > length - o) {
          fail('a literal goes beyond the declared $length bytes', start);
        }
        out.setRange(o, o + literalLength, input, i);
        i += literalLength;
        o += literalLength;
        continue;
      case 1:
        size = 4 + ((tag >> 2) & 7);
        distance = ((tag >> 5) << 8) | read(1);
      case 2:
        size = (tag >> 2) + 1;
        distance = read(2);
      default:
        size = (tag >> 2) + 1;
        distance = read(4);
    }
    if (distance == 0 || distance > o) {
      fail('a copy reaches $distance bytes back, but $o are written', start);
    }
    if (size > length - o) {
      fail('a copy goes beyond the declared $length bytes', start);
    }
    // Byte by byte: the copy may overlap what it writes.
    for (var k = 0; k < size; k++, o++) {
      out[o] = out[o - distance];
    }
  }
  if (o != length) {
    fail('it holds $o bytes, but declares $length', input.length);
  }
  return out;
}

final Uint32List _crcTable = Uint32List.fromList(
  List.generate(256, (i) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = c & 1 == 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  }),
);

/// The CRC32 of [bytes], as zlib computes it (IEEE 802.3).
int crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  }
  return c ^ 0xffffffff;
}
