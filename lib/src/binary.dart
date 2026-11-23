import 'dart:convert';
import 'dart:typed_data';

import 'exceptions.dart';

const _utf8Strict = Utf8Decoder();

/// For each byte: its lower case if it is a hexadecimal digit, else 0.
final Uint8List _uuidLower = () {
  final table = Uint8List(256);
  for (var c = 0x30; c <= 0x39; c++) {
    table[c] = c;
  }
  for (var c = 0x61; c <= 0x66; c++) {
    table[c] = c;
    table[c - 0x20] = c;
  }
  return table;
}();

/// The ends of the five groups of hexadecimal digits of a UUID; a `-` follows each but the last.
const _uuidGroupEnds = [8, 13, 18, 23, 36];

/// Whether the 36 bytes of [bytes] from [s] are a UUID: 8-4-4-4-12 hexadecimal digits of
/// either case; and whether any digit is in upper case.
(bool, bool) _uuidBytes(Uint8List bytes, int s) {
  final table = _uuidLower;
  var upper = false;
  var i = 0;
  for (final end in _uuidGroupEnds) {
    for (; i < end; i++) {
      final c = bytes[s + i];
      final lower = table[c];
      if (lower == 0) return (false, false);
      if (c != lower) upper = true;
    }
    if (end < 36 && bytes[s + i++] != 0x2d) return (false, false);
  }
  return (true, upper);
}

/// Thrown instead of a [DecodeException] by a [BinaryReader] whose input is [partial] when a
/// read needs bytes beyond its end: the input must reach [end] before the read can succeed.
final class InputUnderflow implements Exception {
  const InputUnderflow(this.end);

  /// The index into the reader's bytes up to which input is needed.
  final int end;
}

/// Reads the binary encoding of Avro from bytes held in memory. Every read checks the
/// remaining input first, so no declared length can make it allocate beyond the input.
///
/// A [partial] reader holds the start of a longer input that is still arriving: a read that
/// runs out of bytes throws [InputUnderflow] instead of [DecodeException].
final class BinaryReader {
  BinaryReader(this._bytes, [this._offset = 0, int? end, this.partial = false])
    : _end = end ?? _bytes.length,
      _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  final int _end;
  int _offset;

  /// Whether more input may follow the bytes of this reader.
  final bool partial;

  /// The offset of the next byte to read.
  int get offset => _offset;

  /// Moves back to [offset], an offset this reader has been at.
  void rewind(int offset) => _offset = offset;

  /// The number of bytes left.
  int get remaining => _end - _offset;

  Never fail(String message, [int? at]) =>
      throw DecodeException(message, offset: at ?? _offset);

  /// Fails with [message] at [at] because [count] bytes from the current offset are needed
  /// and fewer are left; throws [InputUnderflow] instead if the reader is [partial].
  Never short(int count, String message, [int? at]) {
    if (!partial) fail(message, at);
    // Saturated, so that a declared length near 2^63 cannot overflow.
    const most = 1 << 53;
    throw InputUnderflow(count > most - _offset ? most : _offset + count);
  }

  void _need(int count) {
    if (count > remaining) {
      short(count, 'needs $count bytes, but only $remaining are left');
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
    if (_end - start >= 10) {
      // No read can run short: the bytes are read without checking what is left.
      final bytes = _bytes;
      var b = bytes[start];
      if (b < 0x80) {
        _offset = start + 1;
        return (b >>> 1) ^ -(b & 1);
      }
      var result = b & 0x7f;
      var shift = 7;
      var i = start + 1;
      while (true) {
        b = bytes[i++];
        if (shift == 63 && b > 1) fail('a long is longer than 64 bits', start);
        result |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
        if (shift > 63) fail('a long is longer than 10 bytes', start);
      }
      _offset = i;
      return (result >>> 1) ^ -(result & 1);
    }
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
  /// [check] sees the length before it is compared with the input.
  int readLength([void Function(int length)? check]) {
    final start = _offset;
    final n = readLong();
    if (n < 0) fail('a length cannot be negative: $n', start);
    check?.call(n);
    if (n > remaining) {
      short(n, 'declares $n bytes, but only $remaining are left', start);
    }
    return n;
  }

  Uint8List readFixed(int size) {
    _need(size);
    final v = _bytes.sublist(_offset, _offset + size);
    _offset += size;
    return v;
  }

  Uint8List readBytes() => readFixed(readLength());

  /// The next [size] bytes as a view of the input, without copying them.
  Uint8List readView(int size) {
    _need(size);
    final v = Uint8List.sublistView(_bytes, _offset, _offset + size);
    _offset += size;
    return v;
  }

  String readString() {
    final start = _offset;
    final n = readLength();
    final s = _offset;
    _offset += n;
    final bytes = _bytes;
    var ascii = true;
    for (var i = s; i < s + n; i++) {
      if (bytes[i] >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) return String.fromCharCodes(bytes, s, s + n);
    try {
      return _utf8Strict.convert(_bytes, s, s + n);
    } on FormatException catch (e) {
      fail('a string is not well-formed UTF-8: ${e.message}', start);
    }
  }

  /// A string that is a UUID, in lower case, as `fromUnderlying` reads one; null, at an
  /// offset of no meaning, if the next datum is no string or not a UUID.
  String? readUuid() {
    final n = readLength();
    final s = _offset;
    if (n != 36) return null;
    final (uuid, upper) = _uuidBytes(_bytes, s);
    if (!uuid) return null;
    _offset = s + 36;
    final text = String.fromCharCodes(_bytes, s, s + 36);
    return upper ? text.toLowerCase() : text;
  }

  void skip(int count) {
    _need(count);
    _offset += count;
  }
}

/// Writes the binary encoding of Avro into a growing buffer.
final class BinaryWriter {
  /// A writer whose buffer starts at [capacity] bytes.
  BinaryWriter([int capacity = 64])
    : _buffer = Uint8List(capacity < 16 ? 16 : capacity);

  Uint8List _buffer;
  ByteData _data = ByteData(0);
  int _length = 0;

  int get length => _length;

  /// Drops what was written after the first [length] bytes.
  void truncate(int length) => _length = length;

  void _ensure(int extra) {
    final needed = _length + extra;
    if (needed <= _buffer.length) return;
    var size = _buffer.length * 2;
    while (size < needed) {
      size *= 2;
    }
    _buffer = Uint8List(size)..setRange(0, _length, _buffer);
    _data = ByteData(0);
  }

  ByteData get _view =>
      _data.lengthInBytes == 0 ? _data = ByteData.sublistView(_buffer) : _data;

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
    _view.setFloat32(_length, v, Endian.little);
    _length += 4;
  }

  void writeDouble(double v) {
    _ensure(8);
    _view.setFloat64(_length, v, Endian.little);
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

  /// Writes [v] as `writeString` does, encoding it straight into the buffer; returns false,
  /// with nothing written, if it holds an unpaired surrogate, which UTF-8 cannot encode.
  bool writeWellFormedString(String v) {
    final n = v.length;
    // First as ASCII, in one pass: one byte per code unit.
    final start = _length;
    writeLong(n);
    _ensure(n);
    final buffer = _buffer;
    var at = _length;
    var ascii = 0;
    for (; ascii < n; ascii++) {
      final c = v.codeUnitAt(ascii);
      if (c >= 0x80) break;
      buffer[at++] = c;
    }
    if (ascii == n) {
      _length = at;
      return true;
    }
    _length = start;
    return _writeWellFormedUtf8(v);
  }

  /// Writes the UUID string [v] in lower case, as a string; returns false, with nothing
  /// written, if it is not a UUID: 8-4-4-4-12 hexadecimal digits of either case.
  bool writeUuid(String v) {
    if (v.length != 36) return false;
    _ensure(37);
    final buffer = _buffer;
    final table = _uuidLower;
    final start = _length;
    buffer[start] = 72; // the zig-zag varint of 36
    var i = 0;
    for (final end in _uuidGroupEnds) {
      for (; i < end; i++) {
        final c = v.codeUnitAt(i);
        final lower = c < 0x100 ? table[c] : 0;
        if (lower == 0) return false;
        buffer[start + 1 + i] = lower;
      }
      if (end < 36) {
        if (v.codeUnitAt(i) != 0x2d) return false;
        buffer[start + 1 + i++] = 0x2d;
      }
    }
    _length = start + 37;
    return true;
  }

  /// Writes [v], which is not ASCII, as [writeWellFormedString] does.
  bool _writeWellFormedUtf8(String v) {
    final n = v.length;
    var size = n;
    for (var i = 0; i < n; i++) {
      final c = v.codeUnitAt(i);
      if (c < 0x80) continue;
      if (c < 0x800) {
        size += 1;
      } else if (c >= 0xd800 && c <= 0xdbff) {
        if (i + 1 >= n) return false;
        final d = v.codeUnitAt(i + 1);
        if (d < 0xdc00 || d > 0xdfff) return false;
        size += 2; // four bytes for two code units
        i++;
      } else if (c >= 0xdc00 && c <= 0xdfff) {
        return false;
      } else {
        size += 2;
      }
    }
    writeLong(size);
    _ensure(size);
    final buffer = _buffer;
    var at = _length;
    for (var i = 0; i < n; i++) {
      var c = v.codeUnitAt(i);
      if (c < 0x80) {
        buffer[at++] = c;
      } else if (c < 0x800) {
        buffer[at++] = 0xc0 | (c >> 6);
        buffer[at++] = 0x80 | (c & 0x3f);
      } else if (c >= 0xd800 && c <= 0xdbff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (v.codeUnitAt(++i) - 0xdc00);
        buffer[at++] = 0xf0 | (c >> 18);
        buffer[at++] = 0x80 | ((c >> 12) & 0x3f);
        buffer[at++] = 0x80 | ((c >> 6) & 0x3f);
        buffer[at++] = 0x80 | (c & 0x3f);
      } else {
        buffer[at++] = 0xe0 | (c >> 12);
        buffer[at++] = 0x80 | ((c >> 6) & 0x3f);
        buffer[at++] = 0x80 | (c & 0x3f);
      }
    }
    _length = at;
    return true;
  }

  /// The bytes written so far, as a copy.
  Uint8List toBytes() => _buffer.sublist(0, _length);

  /// The bytes written, without a copy when they fill the buffer; the writer cannot be used
  /// after.
  Uint8List takeBytes() =>
      _length == _buffer.length ? _buffer : _buffer.sublist(0, _length);
}
