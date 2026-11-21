/// The failures of this package. Every failure is one of the subtypes, so a `switch` over an
/// [AvroException] can handle each cause.
sealed class AvroException implements Exception {
  const AvroException(this.message);

  /// What went wrong, in words.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A schema's JSON is not a valid Avro schema.
final class SchemaParseException extends AvroException {
  const SchemaParseException(super.message, {this.path});

  /// Where in the schema the problem is, for example `Memo.fields[1].type`; null at the root.
  final String? path;

  @override
  String toString() => path == null
      ? super.toString()
      : 'SchemaParseException at $path: $message';
}

/// A writer schema does not resolve against a reader schema.
final class ResolutionException extends AvroException {
  const ResolutionException(super.message, {required this.path});

  /// The path to the part of the schemas that does not resolve, for example `Memo.written`.
  final String path;

  @override
  String toString() => 'ResolutionException at $path: $message';
}

/// The bytes are not a valid encoding of the schema.
final class DecodeException extends AvroException {
  const DecodeException(
    super.message, {
    required this.offset,
    this.path,
    this.blockOffset,
  });

  /// The byte offset at which decoding failed. For a record of a container file, it counts
  /// from the start of the record's block after decompression.
  final int offset;

  /// The path to the value being decoded, if known.
  final String? path;

  /// For a record of a container file, the file offset at which its block starts; null
  /// otherwise.
  final int? blockOffset;

  @override
  String toString() =>
      'DecodeException at byte $offset'
      '${blockOffset == null ? '' : ' of the block at byte $blockOffset'}'
      '${path == null ? '' : ' ($path)'}: $message';
}

/// A value does not fit the schema it is encoded with.
final class EncodeException extends AvroException {
  const EncodeException(super.message, {required this.path});

  /// The path to the value, for example `$.written.year`.
  final String path;

  @override
  String toString() => 'EncodeException at $path: $message';
}

/// Input exceeds one of the [AvroLimits].
final class LimitExceededException extends AvroException {
  const LimitExceededException(super.message, {required this.limit});

  /// The name of the field of `AvroLimits` that was exceeded.
  final String limit;
}

/// A container file uses a compression this package does not support.
final class UnsupportedCompressionException extends AvroException {
  const UnsupportedCompressionException(
    super.message, {
    required this.compression,
  });

  /// The value of the file's `avro.codec` metadata.
  final String compression;
}
