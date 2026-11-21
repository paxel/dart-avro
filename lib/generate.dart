/// The generator of `dart run avro:generate` as a library, for build steps that have schema
/// texts without files: [generateDart] turns schema texts into the Dart source of their
/// classes, without reading or writing files and without formatting the source.
library;

export 'src/generate/library.dart'
    show GenerateException, GeneratedLibrary, SchemaSource, generateDart;
