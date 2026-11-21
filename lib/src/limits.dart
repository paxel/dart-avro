/// Limits on untrusted input. A `null` field means no limit.
///
/// Whatever the limits, a declared length or count is always checked against the remaining
/// input before anything is allocated, negative lengths are rejected, and strings must be
/// well-formed UTF-8.
final class AvroLimits {
  /// The defaults: generous, but finite, so that a small input cannot expand without bound.
  const AvroLimits({
    this.maxBlockBytes = 64 * 1024 * 1024,
    this.maxTotalBytes = 1024 * 1024 * 1024,
    this.maxSchemaBytes = 1024 * 1024,
    this.maxSchemaDepth = 64,
  });

  /// No limits beyond the checks that are always on.
  static const AvroLimits none = AvroLimits(
    maxBlockBytes: null,
    maxTotalBytes: null,
    maxSchemaBytes: null,
    maxSchemaDepth: null,
  );

  /// The size of one data block of a container file after decompression.
  final int? maxBlockBytes;

  /// The size of all data blocks of a container file together after decompression.
  final int? maxTotalBytes;

  /// The size of one schema's JSON text, in UTF-8 bytes.
  final int? maxSchemaBytes;

  /// The nesting depth of a schema's JSON text.
  final int? maxSchemaDepth;
}
