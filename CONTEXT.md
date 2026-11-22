# avro

A pure-Dart implementation of Apache Avro 1.12, for the Dart VM, AOT and the web through dart2wasm: schemas, binary, JSON and single-object encoding, schema resolution and compatibility, sort order, fingerprints, object container files, and typed classes generated from schemas.

## Language

### Schemas

**Writer schema**:
The schema the data was encoded with.
_Avoid_: source schema, file schema (when the role is meant)

**Reader schema**:
The schema the caller wants the data in; the writer schema is resolved against it.
_Avoid_: target schema, expected schema

**Resolution**:
The mapping from a writer schema to a reader schema, as the Avro specification defines it.
_Avoid_: migration, evolution (for the mapping itself)

**Compatibility**:
Whether data of a writer schema can be read as a reader schema by resolution, as checked from the two schemas without data.
_Avoid_: evolution (for the check)

**Canonical form**:
The Parsing Canonical Form of a schema, as the Avro specification defines it.
_Avoid_: normalized schema

**Fingerprint**:
A hash of a schema's canonical form: CRC-64-AVRO, MD5 or SHA-256.
_Avoid_: schema id, schema hash

**Props**:
The attributes of a schema or a field that the Avro specification does not define.
_Avoid_: custom properties, extra attributes, metadata (that is the file's)

### Values

**Codec**:
The object that encodes and decodes values for one writer schema and one reader schema.
_Avoid_: serializer, datum writer, datum reader

**Datum**:
One encoded value of a schema.
_Avoid_: record (unless the schema is a record), message

**Branch**:
The member of a union schema that a value belongs to.
_Avoid_: union member, alternative, variant

**Sort order**:
The order the Avro specification defines on the values of a schema, by which values and their encodings are compared.
_Avoid_: collation, sorting (for the order itself)

### Container files

**Container file**:
An Avro object container file: header, then data blocks.
_Avoid_: Avro file (ambiguous), archive

**Header**:
The magic, the metadata and the sync marker at the start of a container file.

**Metadata**:
The key-value map in a container file's header.
_Avoid_: props (those are a schema's), headers

**Block**:
A run of datums in a container file, compressed together and followed by the sync marker.
_Avoid_: chunk, batch, page

**Sync marker**:
The 16 bytes that end every block of a container file.

**Compression**:
How the blocks of a container file are compressed: `null`, `deflate`, `snappy`, `bzip2`, `xz` or `zstandard`. The Avro specification calls it the file's codec.
_Avoid_: codec (taken by the encoding object above)

### Single-object encoding

**Single-object header**:
The marker `C3 01` and the writer schema's CRC-64-AVRO fingerprint that precede a datum in single-object encoding.
