import 'dart:typed_data';

import 'binary.dart';
import 'exceptions.dart';
import 'schema.dart';

/// A calendar date with no time zone: the Avro logical type `date`.
final class AvroDate implements Comparable<AvroDate> {
  const AvroDate(this.year, this.month, this.day);

  /// The date [days] days after 1 January 1970.
  factory AvroDate.fromEpochDays(int days) {
    final (y, m, d) = _civilFromDays(days);
    return AvroDate(y, m, d);
  }

  final int year;
  final int month;
  final int day;

  /// The number of days from 1 January 1970.
  int get epochDays => _daysFromCivil(year, month, day);

  @override
  bool operator ==(Object other) =>
      other is AvroDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  int compareTo(AvroDate other) => epochDays.compareTo(other.epochDays);

  @override
  String toString() => '${_pad(year, 4)}-${_pad(month, 2)}-${_pad(day, 2)}';
}

/// A date and time of day with no time zone: the Avro logical types
/// `local-timestamp-millis`, `local-timestamp-micros` and `local-timestamp-nanos`.
final class AvroLocalTimestamp implements Comparable<AvroLocalTimestamp> {
  const AvroLocalTimestamp(
    this.year,
    this.month,
    this.day, [
    this.hour = 0,
    this.minute = 0,
    this.second = 0,
    this.nanosecond = 0,
  ]);

  /// The wall-clock time [nanoseconds] after 1 January 1970 00:00.
  factory AvroLocalTimestamp.fromEpochNanoseconds(int nanoseconds) =>
      _fromUnits(nanoseconds, 1);

  /// The wall-clock time [microseconds] after 1 January 1970 00:00.
  factory AvroLocalTimestamp.fromEpochMicroseconds(int microseconds) =>
      _fromUnits(microseconds, 1000);

  /// The wall-clock time [milliseconds] after 1 January 1970 00:00.
  factory AvroLocalTimestamp.fromEpochMilliseconds(int milliseconds) =>
      _fromUnits(milliseconds, 1000000);

  static AvroLocalTimestamp _fromUnits(int units, int nanosPerUnit) {
    final unitsPerDay = _nanosPerDay ~/ nanosPerUnit;
    final rest = units % unitsPerDay * nanosPerUnit;
    final days = (units - units % unitsPerDay) ~/ unitsPerDay;
    final (y, m, d) = _civilFromDays(days);
    return AvroLocalTimestamp(
      y,
      m,
      d,
      rest ~/ 3600000000000,
      rest ~/ 60000000000 % 60,
      rest ~/ 1000000000 % 60,
      rest % 1000000000,
    );
  }

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;

  /// The fraction of the second, in nanoseconds.
  final int nanosecond;

  /// The nanoseconds of the day after midnight.
  int get _nanosOfDay =>
      ((hour * 60 + minute) * 60 + second) * 1000000000 + nanosecond;

  int get _epochDays => _daysFromCivil(year, month, day);

  /// The milliseconds from 1 January 1970 00:00, or null if a finer fraction would be lost.
  int? get epochMilliseconds => nanosecond % 1000000 == 0
      ? _epochDays * 86400000 + _nanosOfDay ~/ 1000000
      : null;

  /// The microseconds from 1 January 1970 00:00, or null if a finer fraction would be lost.
  int? get epochMicroseconds => nanosecond % 1000 == 0
      ? _epochDays * 86400000000 + _nanosOfDay ~/ 1000
      : null;

  /// The nanoseconds from 1 January 1970 00:00.
  int get epochNanoseconds => _epochDays * _nanosPerDay + _nanosOfDay;

  /// This wall-clock time in the device's local time zone, to the microsecond.
  DateTime toDateTime() => DateTime(
    year,
    month,
    day,
    hour,
    minute,
    second,
    nanosecond ~/ 1000000,
    nanosecond ~/ 1000 % 1000,
  );

  @override
  bool operator ==(Object other) =>
      other is AvroLocalTimestamp &&
      other._epochDays == _epochDays &&
      other._nanosOfDay == _nanosOfDay;

  @override
  int get hashCode => Object.hash(_epochDays, _nanosOfDay);

  @override
  int compareTo(AvroLocalTimestamp other) {
    final d = _epochDays.compareTo(other._epochDays);
    return d != 0 ? d : _nanosOfDay.compareTo(other._nanosOfDay);
  }

  @override
  String toString() =>
      '${AvroDate(year, month, day)}T${_pad(hour, 2)}:${_pad(minute, 2)}:'
      '${_pad(second, 2)}.${_pad(nanosecond, 9)}';
}

/// An instant to the nanosecond: the Avro logical type `timestamp-nanos`.
final class AvroTimestampNanos implements Comparable<AvroTimestampNanos> {
  const AvroTimestampNanos(this.epochNanoseconds);

  /// The instant of [time], to the microsecond.
  AvroTimestampNanos.fromDateTime(DateTime time)
    : epochNanoseconds = time.microsecondsSinceEpoch * 1000;

  /// The nanoseconds from 1 January 1970 00:00:00 UTC.
  final int epochNanoseconds;

  /// The instant in UTC, truncated to the microsecond.
  DateTime toDateTime() => DateTime.fromMicrosecondsSinceEpoch(
    (epochNanoseconds - epochNanoseconds % 1000) ~/ 1000,
    isUtc: true,
  );

  @override
  bool operator ==(Object other) =>
      other is AvroTimestampNanos && other.epochNanoseconds == epochNanoseconds;

  @override
  int get hashCode => epochNanoseconds.hashCode;

  @override
  int compareTo(AvroTimestampNanos other) =>
      epochNanoseconds.compareTo(other.epochNanoseconds);

  @override
  String toString() => 'AvroTimestampNanos($epochNanoseconds)';
}

/// An arbitrary-precision decimal, [unscaled] × 10^-[scale]: the Avro logical types
/// `decimal` and `big-decimal`.
final class AvroDecimal {
  const AvroDecimal(this.unscaled, this.scale);

  final BigInt unscaled;
  final int scale;

  @override
  bool operator ==(Object other) =>
      other is AvroDecimal &&
      other.unscaled == unscaled &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(unscaled, scale);

  @override
  String toString() {
    if (scale <= 0) {
      return (unscaled * BigInt.from(10).pow(-scale)).toString();
    }
    final digits = unscaled.abs().toString().padLeft(scale + 1, '0');
    final sign = unscaled.isNegative ? '-' : '';
    final point = digits.length - scale;
    return '$sign${digits.substring(0, point)}.${digits.substring(point)}';
  }
}

/// An amount of months, days and milliseconds: the Avro logical type `duration`.
final class AvroDuration {
  const AvroDuration(this.months, this.days, this.milliseconds);

  final int months;
  final int days;
  final int milliseconds;

  @override
  bool operator ==(Object other) =>
      other is AvroDuration &&
      other.months == months &&
      other.days == days &&
      other.milliseconds == milliseconds;

  @override
  int get hashCode => Object.hash(months, days, milliseconds);

  @override
  String toString() => 'AvroDuration($months, $days, $milliseconds)';
}

const _nanosPerDay = 86400000000000;

String _pad(int v, int width) => v < 0
    ? '-${(-v).toString().padLeft(width, '0')}'
    : '$v'.padLeft(width, '0');

// Howard Hinnant's algorithms for the proleptic Gregorian calendar.
int _daysFromCivil(int y, int m, int d) {
  final yy = m <= 2 ? y - 1 : y;
  final era = (yy >= 0 ? yy : yy - 399) ~/ 400;
  final yoe = yy - era * 400;
  final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468;
}

(int, int, int) _civilFromDays(int days) {
  final z = days + 719468;
  final era = (z >= 0 ? z : z - 146096) ~/ 146097;
  final doe = z - era * 146097;
  final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
  final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
  final mp = (5 * doy + 2) ~/ 153;
  final d = doy - (153 * mp + 2) ~/ 5 + 1;
  final m = mp < 10 ? mp + 3 : mp - 9;
  return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d);
}

/// The logical types this package maps to Dart values.
enum Logical {
  decimal,
  bigDecimal,
  uuid,
  date,
  timeMillis,
  timeMicros,
  timestampMillis,
  timestampMicros,
  timestampNanos,
  localTimestampMillis,
  localTimestampMicros,
  localTimestampNanos,
  duration,
}

final _logicals = Expando<(Logical?,)>();

/// The logical type of [schema] if it is known and valid for its underlying type; null
/// otherwise, and the value is read as the underlying type.
Logical? logicalOf(Schema schema) =>
    (_logicals[schema] ??= (_logicalOf(schema),)).$1;

Logical? _logicalOf(Schema s) {
  final type = s.type;
  return switch (s.logicalType) {
    'decimal' when (type == 'bytes' || type == 'fixed') && _decimalValid(s) =>
      Logical.decimal,
    'big-decimal' when type == 'bytes' => Logical.bigDecimal,
    'uuid' when type == 'string' || (s is FixedSchema && s.size == 16) =>
      Logical.uuid,
    'date' when type == 'int' => Logical.date,
    'time-millis' when type == 'int' => Logical.timeMillis,
    'time-micros' when type == 'long' => Logical.timeMicros,
    'timestamp-millis' when type == 'long' => Logical.timestampMillis,
    'timestamp-micros' when type == 'long' => Logical.timestampMicros,
    'timestamp-nanos' when type == 'long' => Logical.timestampNanos,
    'local-timestamp-millis' when type == 'long' =>
      Logical.localTimestampMillis,
    'local-timestamp-micros' when type == 'long' =>
      Logical.localTimestampMicros,
    'local-timestamp-nanos' when type == 'long' => Logical.localTimestampNanos,
    'duration' when s is FixedSchema && s.size == 12 => Logical.duration,
    _ => null,
  };
}

(int precision, int scale) decimalParameters(Schema s) {
  final json = s.json as Map<String, Object?>;
  return (json['precision']! as int, (json['scale'] ?? 0) as int);
}

bool _decimalValid(Schema s) {
  final json = s.json;
  if (json is! Map<String, Object?>) return false;
  final precision = json['precision'];
  final scale = json['scale'] ?? 0;
  if (precision is! int || scale is! int) return false;
  if (precision <= 0 || scale < 0 || scale > precision) return false;
  if (s is FixedSchema) {
    // floor(log10(2^(8n - 1) - 1)) digits fit n bytes.
    final max = (BigInt.one << (8 * s.size - 1)) - BigInt.one;
    if (precision > max.toString().length - 1) return false;
  }
  return true;
}

/// Whether [value] is a UUID in its text form: 8-4-4-4-12 hexadecimal digits of either case.
bool isUuid(String value) {
  if (value.length != 36) return false;
  for (var i = 0; i < 36; i++) {
    final c = value.codeUnitAt(i);
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != 0x2d) return false;
    } else if (!((c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x46) ||
        (c >= 0x61 && c <= 0x66))) {
      return false;
    }
  }
  return true;
}

/// Whether [value] is a Dart value of the logical type [l].
bool fitsLogical(Logical l, Object? value) => switch (l) {
  Logical.decimal || Logical.bigDecimal => value is AvroDecimal,
  Logical.uuid => value is String && isUuid(value),
  Logical.date => value is AvroDate,
  Logical.timeMillis || Logical.timeMicros => value is Duration,
  Logical.timestampMillis || Logical.timestampMicros => value is DateTime,
  Logical.timestampNanos => value is AvroTimestampNanos,
  Logical.localTimestampMillis ||
  Logical.localTimestampMicros ||
  Logical.localTimestampNanos => value is AvroLocalTimestamp,
  Logical.duration => value is AvroDuration,
};

/// The value of the underlying type that encodes the logical [value].
Object? toUnderlying(Logical l, Schema schema, Object? value, String path) {
  Never wrong(String expected) => throw EncodeException(
    'expected $expected for ${schema.logicalType}, got ${value.runtimeType}',
    path: path,
  );
  Never lost(String what) => throw EncodeException(
    '$value would lose its $what in ${schema.logicalType}',
    path: path,
  );
  if (l == Logical.uuid && value is String && !fitsLogical(l, value)) {
    throw EncodeException('"$value" is not a UUID', path: path);
  }
  if (!fitsLogical(l, value)) {
    wrong(switch (l) {
      Logical.decimal || Logical.bigDecimal => 'AvroDecimal',
      Logical.uuid => 'a UUID String',
      Logical.date => 'AvroDate',
      Logical.timeMillis || Logical.timeMicros => 'Duration',
      Logical.timestampMillis || Logical.timestampMicros => 'DateTime',
      Logical.timestampNanos => 'AvroTimestampNanos',
      Logical.localTimestampMillis ||
      Logical.localTimestampMicros ||
      Logical.localTimestampNanos => 'AvroLocalTimestamp',
      Logical.duration => 'AvroDuration',
    });
  }
  switch (l) {
    case Logical.decimal:
      final d = value! as AvroDecimal;
      final (precision, scale) = decimalParameters(schema);
      if (d.scale != scale) {
        throw EncodeException(
          'the scale ${d.scale} is not the schema\'s $scale',
          path: path,
        );
      }
      if (d.unscaled.abs().toString().length > precision) {
        throw EncodeException(
          '${d.unscaled} has more than $precision digits',
          path: path,
        );
      }
      final size = schema is FixedSchema ? schema.size : null;
      final bytes = _twosComplement(d.unscaled, size);
      if (bytes == null) {
        throw EncodeException(
          '${d.unscaled} does not fit $size bytes',
          path: path,
        );
      }
      return bytes;
    case Logical.bigDecimal:
      final d = value! as AvroDecimal;
      return (BinaryWriter()
            ..writeBytes(_twosComplement(d.unscaled, null)!)
            ..writeLong(d.scale))
          .toBytes();
    case Logical.uuid:
      final text = (value! as String).toLowerCase();
      if (schema is! FixedSchema) return text;
      final hex = text.replaceAll('-', '');
      return Uint8List.fromList([
        for (var i = 0; i < 32; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    case Logical.date:
      final days = (value! as AvroDate).epochDays;
      if (days < -0x80000000 || days > 0x7fffffff) {
        throw EncodeException('$value is beyond an int of days', path: path);
      }
      return days;
    case Logical.timeMillis:
      final us = (value! as Duration).inMicroseconds;
      if (us % 1000 != 0) lost('microseconds');
      return us ~/ 1000;
    case Logical.timeMicros:
      return (value! as Duration).inMicroseconds;
    case Logical.timestampMillis:
      final t = value! as DateTime;
      if (t.microsecond != 0) lost('microseconds');
      return t.millisecondsSinceEpoch;
    case Logical.timestampMicros:
      return (value! as DateTime).microsecondsSinceEpoch;
    case Logical.timestampNanos:
      return (value! as AvroTimestampNanos).epochNanoseconds;
    case Logical.localTimestampMillis:
      return (value! as AvroLocalTimestamp).epochMilliseconds ??
          lost('fraction of a millisecond');
    case Logical.localTimestampMicros:
      return (value! as AvroLocalTimestamp).epochMicroseconds ??
          lost('fraction of a microsecond');
    case Logical.localTimestampNanos:
      return (value! as AvroLocalTimestamp).epochNanoseconds;
    case Logical.duration:
      final d = value! as AvroDuration;
      for (final part in [d.months, d.days, d.milliseconds]) {
        if (part < 0 || part > 0xffffffff) {
          throw EncodeException(
            '$part is not an unsigned 32-bit number',
            path: path,
          );
        }
      }
      final out = Uint8List(12);
      ByteData.sublistView(out)
        ..setUint32(0, d.months, Endian.little)
        ..setUint32(4, d.days, Endian.little)
        ..setUint32(8, d.milliseconds, Endian.little);
      return out;
  }
}

/// The logical value of the underlying [value]; [fail] reports a value that has none.
Object? fromUnderlying(
  Logical l,
  Schema schema,
  Object? value,
  Never Function(String message) fail,
) {
  switch (l) {
    case Logical.decimal:
      final (_, scale) = decimalParameters(schema);
      return AvroDecimal(_fromTwosComplement(value! as Uint8List), scale);
    case Logical.bigDecimal:
      final input = BinaryReader(value! as Uint8List);
      final BigInt unscaled;
      final int scale;
      try {
        unscaled = _fromTwosComplement(input.readBytes());
        scale = input.readInt();
      } on DecodeException catch (e) {
        fail('not a big-decimal: ${e.message}');
      }
      if (input.remaining != 0) fail('a big-decimal has bytes left over');
      return AvroDecimal(unscaled, scale);
    case Logical.uuid:
      if (value is String) {
        if (!isUuid(value)) fail('"$value" is not a UUID');
        return value.toLowerCase();
      }
      final hex = [
        for (final b in value! as Uint8List)
          b.toRadixString(16).padLeft(2, '0'),
      ].join();
      return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    case Logical.date:
      return AvroDate.fromEpochDays(value! as int);
    case Logical.timeMillis:
      return Duration(milliseconds: value! as int);
    case Logical.timeMicros:
      return Duration(microseconds: value! as int);
    case Logical.timestampMillis:
    case Logical.timestampMicros:
      final v = value! as int;
      try {
        return l == Logical.timestampMillis
            ? DateTime.fromMillisecondsSinceEpoch(v, isUtc: true)
            : DateTime.fromMicrosecondsSinceEpoch(v, isUtc: true);
      } on ArgumentError {
        fail('$v is beyond the range of a DateTime');
      }
    case Logical.timestampNanos:
      return AvroTimestampNanos(value! as int);
    case Logical.localTimestampMillis:
      return AvroLocalTimestamp.fromEpochMilliseconds(value! as int);
    case Logical.localTimestampMicros:
      return AvroLocalTimestamp.fromEpochMicroseconds(value! as int);
    case Logical.localTimestampNanos:
      return AvroLocalTimestamp.fromEpochNanoseconds(value! as int);
    case Logical.duration:
      final data = ByteData.sublistView(value! as Uint8List);
      return AvroDuration(
        data.getUint32(0, Endian.little),
        data.getUint32(4, Endian.little),
        data.getUint32(8, Endian.little),
      );
  }
}

/// The big-endian two's complement of [v], in the fewest bytes or sign-extended to [size];
/// null if it does not fit [size].
Uint8List? _twosComplement(BigInt v, int? size) {
  final bits = v.bitLength + 1;
  final needed = (bits + 7) ~/ 8;
  if (size != null && needed > size) return null;
  final n = size ?? needed;
  final out = Uint8List(n);
  var x = v.toUnsigned(8 * n);
  for (var i = n - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

BigInt _fromTwosComplement(Uint8List bytes) {
  if (bytes.isEmpty) return BigInt.zero;
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v.toSigned(8 * bytes.length);
}
