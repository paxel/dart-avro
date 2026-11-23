// The compiled encoder and decoder of a codec (avro-1037, ADR 11): one closure per schema,
// compiled once, instead of a walk of the schema tree for every value.
//
// They are the fast path only. They build no paths and no messages: anything they do not
// accept, they give up on, and the codec runs the tree walk of _Encoder or _Decoder on the
// same input again, which throws exactly what it always has. So both must accept only what
// the tree walk accepts, and produce exactly what it produces.

part of 'codec.dart';

/// Thrown by the compiled code to give up; never leaves the codec.
final class _GiveUp {
  const _GiveUp();
}

const _giveUp = _GiveUp();

typedef _Enc = void Function(BinaryWriter out, Object? value, int depth);
typedef _Dec = Object? Function(BinaryReader input, int depth);

/// The deepest value depth [limits] allow.
int _maxDepth(AvroLimits limits) => limits.maxValueDepth ?? (1 << 62);

/// A record's closure, filled once the record's fields are compiled; a record that refers to
/// itself calls it through here.
final class _Slot<F> {
  F? fn;
}

/// Compiles the encoder of a schema and everything in it.
final class _EncoderCompiler {
  _EncoderCompiler(AvroLimits limits) : maxDepth = _maxDepth(limits);

  final int maxDepth;
  final Map<Schema, _Slot<_Enc>> _records = Map.identity();

  _Enc compile(Schema schema) {
    final logical = logicalOf(schema);
    final raw = _raw(schema);
    if (logical == null) return raw;
    final max = maxDepth;
    if (logical == Logical.uuid && schema is PrimitiveSchema) {
      // A UUID string, as toUnderlying writes it: checked, in lower case.
      return (out, value, depth) {
        if (depth > max || value is! String || !out.writeUuid(value)) {
          throw _giveUp;
        }
      };
    }
    return (out, value, depth) {
      if (depth > max || value is Branch) throw _giveUp;
      raw(out, toUnderlying(logical, schema, value, ''), depth);
    };
  }

  _Enc _raw(Schema schema) {
    final max = maxDepth;
    switch (schema) {
      case PrimitiveSchema(type: 'null'):
        return (out, value, depth) {
          if (depth > max || value != null) throw _giveUp;
        };
      case PrimitiveSchema(type: 'boolean'):
        return (out, value, depth) {
          if (depth > max || value is! bool) throw _giveUp;
          out.writeByte(value ? 1 : 0);
        };
      case PrimitiveSchema(type: 'int'):
        return (out, value, depth) {
          if (depth > max || value is! int || !_isInt32(value)) throw _giveUp;
          out.writeLong(value);
        };
      case PrimitiveSchema(type: 'long'):
        return (out, value, depth) {
          if (depth > max || value is! int) throw _giveUp;
          out.writeLong(value);
        };
      case PrimitiveSchema(type: 'float'):
        return (out, value, depth) {
          if (depth > max || value is! num) throw _giveUp;
          out.writeFloat(value.toDouble());
        };
      case PrimitiveSchema(type: 'double'):
        return (out, value, depth) {
          if (depth > max || value is! num) throw _giveUp;
          out.writeDouble(value.toDouble());
        };
      case PrimitiveSchema(type: 'bytes'):
        return (out, value, depth) {
          if (depth > max || value is! Uint8List) throw _giveUp;
          out.writeBytes(value);
        };
      case PrimitiveSchema(type: 'string'):
        return (out, value, depth) {
          if (depth > max || value is! String) throw _giveUp;
          if (!out.writeWellFormedString(value)) throw _giveUp;
        };
      case PrimitiveSchema():
        throw StateError('unknown primitive ${schema.type}');
      case FixedSchema(:final size):
        return (out, value, depth) {
          if (depth > max || value is! Uint8List || value.length != size) {
            throw _giveUp;
          }
          out.writeFixed(value);
        };
      case EnumSchema(:final symbols):
        final index = <String, int>{};
        for (var i = symbols.length - 1; i >= 0; i--) {
          index[symbols[i]] = i;
        }
        return (out, value, depth) {
          if (depth > max || value is! String) throw _giveUp;
          out.writeLong(index[value] ?? (throw _giveUp));
        };
      case ArraySchema(:final items):
        final item = compile(items);
        return (out, value, depth) {
          if (depth > max || value is! List<Object?> || value is Uint8List) {
            throw _giveUp;
          }
          final n = value.length;
          if (n > 0) {
            out.writeLong(n);
            for (var i = 0; i < n; i++) {
              item(out, value[i], depth + 1);
            }
          }
          out.writeLong(0);
        };
      case MapSchema(:final values):
        final valueFn = compile(values);
        return (out, value, depth) {
          if (depth > max || value is! Map<String, Object?>) throw _giveUp;
          if (value.isNotEmpty) {
            out.writeLong(value.length);
            for (final e in value.entries) {
              if (!out.writeWellFormedString(e.key)) throw _giveUp;
              valueFn(out, e.value, depth + 1);
            }
          }
          out.writeLong(0);
        };
      case RecordSchema():
        return _record(schema);
      case UnionSchema(:final branches):
        return _union(branches);
    }
  }

  _Enc _record(RecordSchema schema) {
    final known = _records[schema];
    if (known != null) {
      // A record within itself: its closure is not there yet, so call it through the slot.
      return known.fn ?? (out, value, depth) => known.fn!(out, value, depth);
    }
    final slot = _Slot<_Enc>();
    _records[schema] = slot;
    final fields = schema.fields;
    final names = [for (final f in fields) f.name];
    final fns = [for (final f in fields) compile(f.schema)];
    final n = fields.length;
    final max = maxDepth;
    final keys = _keysOf(schema);
    _Enc fn;
    fn = (out, value, depth) {
      if (value is _RecordMap &&
          identical(value._keys, keys) &&
          value._map == null) {
        // A record decoded with this schema, its fields still those of the schema.
        final values = value._values;
        if (depth > max) throw _giveUp;
        for (var i = 0; i < n; i++) {
          fns[i](out, values[i], depth + 1);
        }
        return;
      }
      // Every field there and no other key: the tree walk throws for anything else.
      if (depth > max || value is! Map<String, Object?> || value.length != n) {
        throw _giveUp;
      }
      if (value is LinkedHashMap<String, Object?>) {
        // Its keys most often come in the schema's order: then its entries are the fields,
        // without a lookup.
        final start = out.length;
        var i = 0;
        value.forEach((key, v) {
          if (i < 0) return;
          if (key != names[i]) {
            i = -1;
            return;
          }
          fns[i](out, v, depth + 1);
          i++;
        });
        if (i == n) return;
        out.truncate(start);
      }
      for (var i = 0; i < n; i++) {
        final name = names[i];
        final v = value[name];
        if (v == null && !value.containsKey(name)) throw _giveUp;
        fns[i](out, v, depth + 1);
      }
    };
    slot.fn = fn;
    return fn;
  }

  _Enc _union(List<Schema> branches) {
    final fns = [for (final b in branches) compile(b)];
    final names = [for (final b in branches) branchName(b)];
    final fits = [for (final b in branches) _fitter(b)];
    final max = maxDepth;
    final count = branches.length;
    final general = _generalUnion(fns, names, fits, max, count);
    final nullIndex = branches.indexWhere((b) => b.type == 'null');
    if (count != 2 || nullIndex < 0 || branches[1 - nullIndex].type == 'null') {
      return general;
    }
    // A union of null and one other branch: null is the null branch, and no other value fits
    // it. Where the other branch's encoder accepts exactly what fits it, it decides alone.
    final other = 1 - nullIndex;
    final otherFn = fns[other];
    final otherFits = _encoderIsFit(branches[other]) ? null : fits[other];
    return (out, value, depth) {
      if (value == null) {
        if (depth + 1 > max) throw _giveUp;
        out.writeLong(nullIndex);
        return;
      }
      if (value is Branch) return general(out, value, depth);
      if (depth > max || (otherFits != null && !otherFits(value))) {
        throw _giveUp;
      }
      out.writeLong(other);
      otherFn(out, value, depth + 1);
    };
  }

  _Enc _generalUnion(
    List<_Enc> fns,
    List<String> names,
    List<bool Function(Object?)> fits,
    int max,
    int count,
  ) {
    return (out, value, depth) {
      if (depth > max) throw _giveUp;
      int index;
      Object? inner;
      if (value is Branch) {
        index = names.indexOf(value.name);
        if (index < 0) throw _giveUp;
        inner = value.value;
      } else {
        index = -1;
        for (var i = 0; i < count; i++) {
          if (fits[i](value)) {
            if (index >= 0) throw _giveUp;
            index = i;
          }
        }
        if (index < 0) throw _giveUp;
        inner = value;
      }
      out.writeLong(index);
      fns[index](out, inner, depth + 1);
    };
  }
}

/// Whether the compiled encoder of [schema] accepts exactly the values that [_fits] says fit
/// it, so that a union need not ask [_fits] first.
bool _encoderIsFit(Schema schema) =>
    logicalOf(schema) == null &&
    switch (schema) {
      PrimitiveSchema(type: 'boolean' || 'long' || 'bytes' || 'string') => true,
      RecordSchema() || ArraySchema() || MapSchema() => true,
      _ => false,
    };

/// The test of [_fits] for [schema], with the common cases as their own closures.
bool Function(Object? value) _fitter(Schema schema) {
  final logical = logicalOf(schema);
  if (logical != null) return (value) => fitsLogical(logical, value);
  return switch (schema) {
    PrimitiveSchema(type: 'null') => (value) => value == null,
    PrimitiveSchema(type: 'boolean') => (value) => value is bool,
    PrimitiveSchema(type: 'long') => (value) => value is int,
    PrimitiveSchema(type: 'float' || 'double') => (value) => value is double,
    PrimitiveSchema(type: 'bytes') => (value) => value is Uint8List,
    PrimitiveSchema(type: 'string') => (value) => value is String,
    PrimitiveSchema(type: 'int') => (value) => value is int && _isInt32(value),
    FixedSchema(:final size) => (
      value,
    ) => value is Uint8List && value.length == size,
    ArraySchema() => (value) => value is List<Object?> && value is! Uint8List,
    MapSchema() => (value) => value is Map<String, Object?>,
    RecordSchema(:final fields) => _recordFitter([
      for (final f in fields) f.name,
    ]),
    _ => (value) => _fitsRaw(schema, value),
  };
}

/// The test of [_fitsRaw] for a record of the fields [names].
bool Function(Object? value) _recordFitter(List<String> names) {
  final n = names.length;
  return (value) {
    if (value is! Map<String, Object?> || value.length != n) return false;
    for (var i = 0; i < n; i++) {
      if (!value.containsKey(names[i])) return false;
    }
    return true;
  };
}

/// Compiles the decoder of a schema and everything in it.
final class _DecoderCompiler {
  _DecoderCompiler(AvroLimits limits, this.decodeBranches)
    : maxDepth = _maxDepth(limits),
      maxZeroSizeItems = limits.maxZeroSizeItems;

  final int maxDepth;
  final int? maxZeroSizeItems;
  final bool decodeBranches;
  final Map<Schema, _Slot<_Dec>> _records = Map.identity();

  _Dec compile(Schema schema) {
    final logical = logicalOf(schema);
    final raw = _raw(schema);
    if (logical == null) return raw;
    if (logical == Logical.uuid && schema is PrimitiveSchema) {
      // As fromUnderlying reads a UUID string: checked, in lower case.
      final max = maxDepth;
      return (input, depth) {
        if (depth > max) throw _giveUp;
        return input.readUuid() ?? (throw _giveUp);
      };
    }
    Never fail(String message) => throw _giveUp;
    return (input, depth) =>
        fromUnderlying(logical, schema, raw(input, depth), fail);
  }

  /// The item count of the next block, checked as [_Decoder.blockCount] checks it.
  int Function(BinaryReader input) _blockCount(Schema items, int extra) {
    final minSize = minEncodedSize(items) + extra;
    final maxZero = maxZeroSizeItems;
    return (input) {
      var count = input.readLong();
      if (count < 0) {
        if (count == -0x8000000000000000) throw _giveUp;
        count = -count;
        input.readLength();
      }
      if (minSize > 0) {
        if (count > input.remaining ~/ minSize) throw _giveUp;
      } else if (maxZero != null && count > maxZero) {
        throw _giveUp;
      }
      return count;
    };
  }

  _Dec _raw(Schema schema) {
    final max = maxDepth;
    switch (schema) {
      case PrimitiveSchema(type: 'null'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return null;
        };
      case PrimitiveSchema(type: 'boolean'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readBoolean();
        };
      case PrimitiveSchema(type: 'int'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readInt();
        };
      case PrimitiveSchema(type: 'long'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readLong();
        };
      case PrimitiveSchema(type: 'float'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readFloat();
        };
      case PrimitiveSchema(type: 'double'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readDouble();
        };
      case PrimitiveSchema(type: 'bytes'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readBytes();
        };
      case PrimitiveSchema(type: 'string'):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readString();
        };
      case PrimitiveSchema():
        throw StateError('unknown primitive ${schema.type}');
      case FixedSchema(:final size):
        return (input, depth) {
          if (depth > max) throw _giveUp;
          return input.readFixed(size);
        };
      case EnumSchema(:final symbols):
        final n = symbols.length;
        return (input, depth) {
          if (depth > max) throw _giveUp;
          final i = input.readInt();
          if (i < 0 || i >= n) throw _giveUp;
          return symbols[i];
        };
      case ArraySchema(:final items):
        final item = compile(items);
        final blockCount = _blockCount(items, 0);
        return (input, depth) {
          if (depth > max) throw _giveUp;
          final out = <Object?>[];
          while (true) {
            final count = blockCount(input);
            if (count == 0) return out;
            for (var i = 0; i < count; i++) {
              out.add(item(input, depth + 1));
            }
          }
        };
      case MapSchema(:final values):
        final valueFn = compile(values);
        final blockCount = _blockCount(values, 1);
        return (input, depth) {
          if (depth > max) throw _giveUp;
          final out = <String, Object?>{};
          while (true) {
            final count = blockCount(input);
            if (count == 0) return out;
            for (var i = 0; i < count; i++) {
              final key = input.readString();
              out[key] = valueFn(input, depth + 1);
            }
          }
        };
      case RecordSchema():
        return _record(schema);
      case UnionSchema(:final branches):
        final fns = [for (final b in branches) compile(b)];
        final names = [
          for (final b in branches)
            decodeBranches && decodesAsBranch(schema, b) ? branchName(b) : null,
        ];
        final n = branches.length;
        return (input, depth) {
          if (depth > max) throw _giveUp;
          final i = input.readInt();
          if (i < 0 || i >= n) throw _giveUp;
          final value = fns[i](input, depth + 1);
          final name = names[i];
          return name == null ? value : Branch(name, value);
        };
    }
  }

  _Dec _record(RecordSchema schema) {
    final known = _records[schema];
    if (known != null) {
      return known.fn ?? (input, depth) => known.fn!(input, depth);
    }
    final slot = _Slot<_Dec>();
    _records[schema] = slot;
    final fields = schema.fields;
    final fns = [for (final f in fields) compile(f.schema)];
    final n = fields.length;
    final max = maxDepth;
    final keys = _keysOf(schema);
    _Dec fn;
    fn = (input, depth) {
      if (depth > max) throw _giveUp;
      final values = List<Object?>.filled(n, null);
      for (var i = 0; i < n; i++) {
        values[i] = fns[i](input, depth + 1);
      }
      return _RecordMap(keys, values);
    };
    slot.fn = fn;
    return fn;
  }
}

final _recordKeys = Expando<_RecordKeys>();

/// The field names of [schema], the same object for every codec.
_RecordKeys _keysOf(RecordSchema schema) => _recordKeys[schema] ??= _RecordKeys(
  [for (final f in schema.fields) f.name],
);

/// The field names of a record, shared by every [_RecordMap] of it.
final class _RecordKeys {
  _RecordKeys(this.names)
    : index = {for (var i = 0; i < names.length; i++) names[i]: i};

  final List<String> names;
  final Map<String, int> index;
}

/// A decoded record: a map of its fields in the schema's order, as a list of values, which
/// is much cheaper to build than a hash map.
///
/// It is a full map. Setting a field's value keeps it a list; anything that adds or removes a
/// key turns it into an ordinary map with the same entries in the same order first.
final class _RecordMap extends MapBase<String, Object?> {
  _RecordMap(this._keys, this._values);

  final _RecordKeys _keys;
  final List<Object?> _values;
  Map<String, Object?>? _map;

  Map<String, Object?> get _asMap => _map ??= <String, Object?>{
    for (var i = 0; i < _values.length; i++) _keys.names[i]: _values[i],
  };

  @override
  Object? operator [](Object? key) {
    final map = _map;
    if (map != null) return map[key];
    final i = _keys.index[key];
    return i == null ? null : _values[i];
  }

  @override
  void operator []=(String key, Object? value) {
    final map = _map;
    if (map == null) {
      final i = _keys.index[key];
      if (i != null) {
        _values[i] = value;
        return;
      }
    }
    _asMap[key] = value;
  }

  @override
  bool containsKey(Object? key) =>
      _map?.containsKey(key) ?? _keys.index.containsKey(key);

  @override
  int get length => _map?.length ?? _values.length;

  @override
  bool get isEmpty => length == 0;

  @override
  bool get isNotEmpty => length != 0;

  @override
  Iterable<String> get keys => _asMap.keys;

  @override
  Iterable<Object?> get values => _asMap.values;

  @override
  Iterable<MapEntry<String, Object?>> get entries => _asMap.entries;

  @override
  void forEach(void Function(String key, Object? value) action) =>
      _asMap.forEach(action);

  @override
  Object? remove(Object? key) => _asMap.remove(key);

  @override
  void clear() => _asMap.clear();
}
