import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';

const _utf8Strict = Utf8Decoder();

/// Reads the binary encoding of Avro from bytes held in memory. Every read checks the
/// remaining input first, so no declared length can make it allocate beyond the input.
final class BinaryReader {
  BinaryReader(this._bytes, [this._offset = 0, int? end])
    : _end = end ?? _bytes.length,
      _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  final int _end;
  int _offset;

  /// The offset of the next byte to read.
  int get offset => _offset;

  /// The number of bytes left.
  int get remaining => _end - _offset;

  Never fail(String message, [int? at]) =>
      throw DecodeException(message, offset: at ?? _offset);

  void _need(int count) {
    if (count > remaining) {
      fail('needs $count bytes, but only $remaining are left');
    }
  }

  int readByte() {
    _need(1);
    return _bytes[_offset++];
  }

  bool readBoolean() {
    final start = _offset;
    final b = readByte();
    if (b > 1) fail('a boolean is 0 or 1, not $b', start);
    return b == 1;
  }

  /// A zig-zag varint of at most 64 bits.
  int readLong() {
    final start = _offset;
    var result = 0;
    var shift = 0;
    while (true) {
      final b = readByte();
      if (shift == 63 && b > 1) fail('a long is longer than 64 bits', start);
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
      if (shift > 63) fail('a long is longer than 10 bytes', start);
    }
    return (result >>> 1) ^ -(result & 1);
  }

  /// A zig-zag varint that must fit 32 bits.
  int readInt() {
    final start = _offset;
    final v = readLong();
    if (v < -0x80000000 || v > 0x7fffffff) {
      fail('an int must fit 32 bits, not $v', start);
    }
    return v;
  }

  double readFloat() {
    _need(4);
    final v = _data.getFloat32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  double readDouble() {
    _need(8);
    final v = _data.getFloat64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  /// A length or count that precedes content: never negative, never beyond the input.
  int readLength() {
    final start = _offset;
    final n = readLong();
    if (n < 0) fail('a length cannot be negative: $n', start);
    if (n > remaining) {
      fail('declares $n bytes, but only $remaining are left', start);
    }
    return n;
  }

  Uint8List readFixed(int size) {
    _need(size);
    final v = Uint8List.fromList(_bytes.sublist(_offset, _offset + size));
    _offset += size;
    return v;
  }

  Uint8List readBytes() => readFixed(readLength());

  String readString() {
    final start = _offset;
    final n = readLength();
    final s = _offset;
    _offset += n;
    try {
      return _utf8Strict.convert(_bytes, s, s + n);
    } on FormatException catch (e) {
      fail('a string is not well-formed UTF-8: ${e.message}', start);
    }
  }

  void skip(int count) {
    _need(count);
    _offset += count;
  }
}

/// Writes the binary encoding of Avro into a growing buffer.
final class BinaryWriter {
  Uint8List _buffer = Uint8List(64);
  int _length = 0;

  int get length => _length;

  void _ensure(int extra) {
    final needed = _length + extra;
    if (needed <= _buffer.length) return;
    var size = _buffer.length * 2;
    while (size < needed) {
      size *= 2;
    }
    _buffer = Uint8List(size)..setRange(0, _length, _buffer);
  }

  void writeByte(int b) {
    _ensure(1);
    _buffer[_length++] = b;
  }

  void writeBoolean(bool v) => writeByte(v ? 1 : 0);

  void writeLong(int v) {
    var z = (v << 1) ^ (v >> 63);
    _ensure(10);
    while (z & ~0x7f != 0) {
      _buffer[_length++] = (z & 0x7f) | 0x80;
      z = z >>> 7;
    }
    _buffer[_length++] = z;
  }

  void writeFloat(double v) {
    _ensure(4);
    ByteData.sublistView(_buffer).setFloat32(_length, v, Endian.little);
    _length += 4;
  }

  void writeDouble(double v) {
    _ensure(8);
    ByteData.sublistView(_buffer).setFloat64(_length, v, Endian.little);
    _length += 8;
  }

  void writeFixed(List<int> v) {
    _ensure(v.length);
    _buffer.setRange(_length, _length + v.length, v);
    _length += v.length;
  }

  void writeBytes(List<int> v) {
    writeLong(v.length);
    writeFixed(v);
  }

  void writeString(String v) => writeBytes(utf8.encode(v));

  /// The bytes written so far, as a copy.
  Uint8List toBytes() =>
      Uint8List.fromList(Uint8List.sublistView(_buffer, 0, _length));
}
