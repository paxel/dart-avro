/// Apache Avro 1.12 for Dart: schemas, binary and single-object encoding, schema resolution,
/// fingerprints and object container files.
library;

export 'src/codec.dart' show AvroCodec, Branch;
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
