/// Apache Avro 1.12 for Dart: schemas, binary, JSON and single-object encoding, schema
/// resolution, fingerprints, and object container files in memory or as streams, in every Avro
/// compression. Typed classes are generated with `dart run avro:generate` or
/// `package:avro/generate.dart`.
library;

export 'src/compatibility.dart'
    show
        IncompatibilityKind,
        Incompatibility,
        SchemaCompatibility,
        checkCompatibility;
export 'src/container.dart' show AvroFileHeader, AvroFileReader, AvroFileWriter;
export 'src/container_stream.dart'
    show AvroFileStreamReader, AvroFileStreamWriter;
export 'src/codec.dart'
    show AvroCodec, Branch, SingleObjectEncoding, SingleObjectHeader;
export 'src/exceptions.dart';
export 'src/fingerprint.dart'
    show SchemaFingerprints, crc64Avro, crc64FromBytes, crc64ToBytes;
export 'src/limits.dart';
export 'src/logical.dart'
    show
        AvroDate,
        AvroDecimal,
        AvroDuration,
        AvroLocalTimestamp,
        AvroTimestampNanos;
export 'src/typed.dart' show AvroType, TypedCodec;
export 'src/schema.dart'
    show
        ArraySchema,
        EnumSchema,
        Field,
        FixedSchema,
        MapSchema,
        NamedSchema,
        PrimitiveSchema,
        RecordSchema,
        Schema,
        UnionSchema;
