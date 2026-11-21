import 'dart:typed_data';

import 'codec.dart';
import 'limits.dart';
import 'schema.dart';

/// Describes a Dart type that represents values of one Avro schema, as `dart run
/// avro:generate` writes for every record: the schema's JSON text and the conversion between
/// the Dart value and the generic value of [AvroCodec].
final class AvroType<T> {
  /// A descriptor of the schema given as [schemaJson], parsed on first use.
  AvroType({
    required this.schemaJson,
    required this.toAvro,
    required this.fromAvro,
  });

  /// The JSON text of the schema, `doc` and attributes included.
  final String schemaJson;

  /// The schema, parsed from [schemaJson] once, on first use.
  late final Schema schema = Schema.parse(schemaJson, limits: AvroLimits.none);

  /// The generic value of [AvroCodec] for a Dart value.
  final Object? Function(T value) toAvro;

  /// The Dart value for a generic value of [AvroCodec], decoded with [schema] as the reader.
  final T Function(Object? value) fromAvro;
}

/// Encodes and decodes values of a Dart type described by an [AvroType].
///
/// Values are always encoded with the type's own schema. Decoding reads data of [writer],
/// which defaults to the type's schema, as the type's schema, with the schema resolution of
/// [AvroCodec], compiled once here.
final class TypedCodec<T> {
  /// A codec for [type]. Throws `ResolutionException` if [writer] does not resolve against the
  /// type's schema.
  TypedCodec(
    this.type, {
    Schema? writer,
    AvroLimits limits = const AvroLimits(),
  }) : avro = AvroCodec(
         writer: writer ?? type.schema,
         reader: type.schema,
         limits: limits,
       ),
       _own = writer == null
           ? null
           : AvroCodec(writer: type.schema, limits: limits);

  /// The type this codec encodes and decodes.
  final AvroType<T> type;

  /// The underlying codec: data of the writer schema, read as the type's schema. Without a
  /// writer schema, its writer is the type's schema, so it also suits an `AvroFileWriter`.
  final AvroCodec avro;

  final AvroCodec? _own;

  AvroCodec get _encoder => _own ?? avro;

  /// Encodes [value] with the type's schema.
  Uint8List encode(T value) => _encoder.encode(type.toAvro(value));

  /// Decodes one datum of the writer schema.
  T decode(Uint8List bytes) => type.fromAvro(avro.decode(bytes));

  /// Encodes [value] with the type's schema in Avro's JSON encoding, as
  /// [AvroCodec.encodeJson] does.
  String encodeJson(T value, {String? indent}) =>
      _encoder.encodeJson(type.toAvro(value), indent: indent);

  /// Decodes one datum of the writer schema in Avro's JSON encoding, as
  /// [AvroCodec.decodeJson] does.
  T decodeJson(String json) => type.fromAvro(avro.decodeJson(json));

  /// Encodes [value] in single-object encoding, with the fingerprint of the type's schema.
  Uint8List encodeSingleObject(T value) =>
      _encoder.encodeSingleObject(type.toAvro(value));

  /// Decodes a datum in single-object encoding, whose fingerprint must be the writer schema's.
  T decodeSingleObject(Uint8List bytes) =>
      type.fromAvro(avro.decodeSingleObject(bytes));
}
