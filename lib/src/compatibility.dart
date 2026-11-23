import 'logical.dart';
import 'resolve.dart';
import 'schema.dart';

/// The kind of an [Incompatibility], named after Apache Avro Java's
/// `SchemaIncompatibilityType` where one matches.
enum IncompatibilityKind {
  /// A named type of the writer has neither the reader's name nor one of its aliases.
  nameMismatch,

  /// The writer's fixed has another size than the reader's.
  fixedSizeMismatch,

  /// The writer's enum has symbols the reader's lacks, and the reader's has no default.
  /// Only data with those symbols fails; a codec for the schemas can still be made.
  missingEnumSymbols,

  /// A field of the reader's record that the writer's lacks has no default.
  readerFieldMissingDefaultValue,

  /// The writer's type neither is the reader's nor promotes to it.
  typeMismatch,

  /// No branch of the reader's union takes the writer's type, or the writer's union has no
  /// branch at all.
  missingUnionBranch,

  /// The writer's and the reader's decimals differ in precision or scale; Java has no such
  /// kind.
  decimalMismatch,
}

/// One reason data of a writer schema cannot be read as a reader schema.
final class Incompatibility {
  const Incompatibility(
    this.kind,
    this.message, {
    required this.readerPath,
    required this.writerPath,
  });

  final IncompatibilityKind kind;

  /// What is incompatible, in words.
  final String message;

  /// Where in the reader schema, in the notation of `ResolutionException` paths: the name
  /// of the schema, then `.field` for a field, `[]` for the items of an array, `{}` for the
  /// values of a map and `<branch>` for a branch of a union, such as `Memo.tags[]`. Unlike a
  /// `ResolutionException` path, which mixes both schemas, it names only the reader's
  /// fields and branches.
  final String readerPath;

  /// Where in the writer schema, as [readerPath] is in the reader's.
  final String writerPath;

  @override
  bool operator ==(Object other) =>
      other is Incompatibility &&
      other.kind == kind &&
      other.message == message &&
      other.readerPath == readerPath &&
      other.writerPath == writerPath;

  @override
  int get hashCode => Object.hash(kind, message, readerPath, writerPath);

  @override
  String toString() =>
      'Incompatibility(${kind.name} at $readerPath, writer $writerPath: $message)';
}

/// Whether data of a writer schema can be read as a reader schema, as [checkCompatibility]
/// finds it.
final class SchemaCompatibility {
  SchemaCompatibility._(List<Incompatibility> incompatibilities)
    : incompatibilities = List.unmodifiable(incompatibilities);

  /// Every incompatibility found, in the order of the schemas; empty if compatible.
  final List<Incompatibility> incompatibilities;

  /// Whether every datum of the writer schema can be read as the reader schema.
  bool get isCompatible => incompatibilities.isEmpty;

  @override
  String toString() => isCompatible
      ? 'SchemaCompatibility(compatible)'
      : 'SchemaCompatibility(${incompatibilities.join(', ')})';
}

/// Checks, without data, whether data of [writer] can be read as [reader] by the schema
/// resolution of `AvroCodec`, and returns every incompatibility found.
///
/// Where an `AvroCodec` for the two throws `ResolutionException`, the result is
/// incompatible. It is also incompatible where only some data fails, for which a codec can
/// still be made: a writer's enum symbol the reader lacks without a default, and a branch of
/// a writer's union that does not resolve.
SchemaCompatibility checkCompatibility({
  required Schema reader,
  required Schema writer,
}) {
  final checker = _Checker();
  checker.check(writer, reader, branchName(writer), branchName(reader));
  return SchemaCompatibility._(checker.found);
}

final class _Checker {
  final found = <Incompatibility>[];
  final readerBranch = readerBranchChooser();

  /// The pairs of records checked or being checked, so that recursion ends.
  final records = <(RecordSchema, RecordSchema)>{};

  void report(
    IncompatibilityKind kind,
    String message,
    String writerPath,
    String readerPath,
  ) => found.add(
    Incompatibility(
      kind,
      message,
      readerPath: readerPath,
      writerPath: writerPath,
    ),
  );

  void check(Schema w, Schema r, String wp, String rp) {
    if (identical(w, r)) return;
    if (w is UnionSchema) {
      if (w.branches.isEmpty) {
        // The resolver rejects it, as no branch resolves.
        report(
          IncompatibilityKind.missingUnionBranch,
          'the writer union has no branch to resolve against ${branchName(r)}',
          wp,
          rp,
        );
      }
      for (final b in w.branches) {
        check(b, r, '$wp<${branchName(b)}>', rp);
      }
      return;
    }
    if (r is UnionSchema) {
      final i = readerBranch(w, r);
      if (i < 0) {
        report(
          IncompatibilityKind.missingUnionBranch,
          'no branch of the reader union ${r.branches.map(branchName).join(', ')} '
          'matches ${branchName(w)}',
          wp,
          rp,
        );
        return;
      }
      final b = r.branches[i];
      check(w, b, wp, '$rp<${branchName(b)}>');
      return;
    }
    switch ((w, r)) {
      case (PrimitiveSchema(type: final a), PrimitiveSchema(type: final b))
          when a == b || promotes(a, b):
        break;
      case (final FixedSchema w, final FixedSchema r):
        checkName(w, r, wp, rp);
        if (w.size != r.size) {
          report(
            IncompatibilityKind.fixedSizeMismatch,
            'the writer fixed has ${w.size} bytes, the reader fixed ${r.size}',
            wp,
            rp,
          );
        }
      case (final ArraySchema w, final ArraySchema r):
        check(w.items, r.items, '$wp[]', '$rp[]');
        return;
      case (final MapSchema w, final MapSchema r):
        check(w.values, r.values, '$wp{}', '$rp{}');
        return;
      case (final EnumSchema w, final EnumSchema r):
        checkName(w, r, wp, rp);
        final missing = [
          for (final s in w.symbols)
            if (!r.symbols.contains(s)) s,
        ];
        if (missing.isNotEmpty && r.defaultSymbol == null) {
          report(
            IncompatibilityKind.missingEnumSymbols,
            'the reader enum lacks the writer symbols ${missing.join(', ')} '
            'and has no default',
            wp,
            rp,
          );
        }
        return;
      case (final RecordSchema w, final RecordSchema r):
        checkName(w, r, wp, rp);
        if (records.add((w, r))) checkFields(w, r, wp, rp);
        return;
      default:
        report(
          IncompatibilityKind.typeMismatch,
          '${branchName(w)} does not resolve to ${branchName(r)}',
          wp,
          rp,
        );
        return;
    }
    if (logicalOf(w) == Logical.decimal &&
        logicalOf(r) == Logical.decimal &&
        decimalParameters(w) != decimalParameters(r)) {
      report(
        IncompatibilityKind.decimalMismatch,
        'the decimals differ in precision or scale',
        wp,
        rp,
      );
    }
  }

  void checkName(NamedSchema w, NamedSchema r, String wp, String rp) {
    if (!namesMatch(w, r)) {
      report(
        IncompatibilityKind.nameMismatch,
        'the writer ${w.type} ${w.fullName} is neither ${r.fullName} nor one of its aliases',
        wp,
        rp,
      );
    }
  }

  /// The fields of the records, matched as the resolver matches them.
  void checkFields(RecordSchema w, RecordSchema r, String wp, String rp) {
    final used = <String>{};
    for (final wf in w.fields) {
      Field? match;
      for (final rf in r.fields) {
        if (rf.name == wf.name) match = rf;
      }
      match ??= r.fields
          .where((rf) => rf.aliases.contains(wf.name))
          .firstOrNull;
      if (match == null || used.contains(match.name)) continue;
      used.add(match.name);
      check(wf.schema, match.schema, '$wp.${wf.name}', '$rp.${match.name}');
    }
    for (final rf in r.fields) {
      if (used.contains(rf.name) || rf.hasDefault) continue;
      report(
        IncompatibilityKind.readerFieldMissingDefaultValue,
        'the reader field "${rf.name}" has no default and the writer lacks it',
        wp,
        '$rp.${rf.name}',
      );
    }
  }
}
