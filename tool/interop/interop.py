"""The Python side of the interop job (ADR 5): writes and reads the cases of cases.json with
the Python avro package, the official Apache library.

    python interop.py write DIR   writes py-<case>-<compression>.avro and py-<case>-<n>.bin
    python interop.py read DIR    reads the dart-* files and compares them with the cases

Run from the repository root.
"""

import datetime
import decimal
import io
import json
import pathlib
import sys

import avro.datafile
import avro.io
import avro.schema

ROOT = pathlib.Path(__file__).resolve().parents[2]
EPOCH = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)


def load_schema(spec):
    if isinstance(spec, str) and spec.startswith("@"):
        return avro.schema.parse((ROOT / spec[1:]).read_text())
    return avro.schema.parse(json.dumps(spec))


def logical(s):
    return getattr(s, "logical_type", None) or s.props.get("logicalType")


def branch_name(s):
    return s.fullname if isinstance(s, avro.schema.NamedSchema) else s.type


def from_json(s, v):
    """The Python value of the interop JSON value v of schema s."""
    lt = logical(s) if not isinstance(s, avro.schema.UnionSchema) else None
    if lt == "date":
        return datetime.date(1970, 1, 1) + datetime.timedelta(days=v)
    if lt in ("time-millis", "time-micros"):
        micros = v * 1000 if lt == "time-millis" else v
        return (datetime.datetime.min + datetime.timedelta(microseconds=micros)).time()
    if lt in ("timestamp-millis", "timestamp-micros"):
        micros = v * 1000 if lt == "timestamp-millis" else v
        return EPOCH + datetime.timedelta(microseconds=micros)
    if lt == "decimal":
        return decimal.Decimal(v)
    t = s.type
    if t in ("bytes", "fixed"):
        return bytes.fromhex(v)
    if t == "array":
        return [from_json(s.items, x) for x in v]
    if t == "map":
        return {k: from_json(s.values, x) for k, x in v.items()}
    if t in ("record", "error"):
        return {f.name: from_json(f.type, v[f.name]) for f in s.fields}
    if t == "union":
        if v is None:
            return None
        ((name, inner),) = v.items()
        (b,) = [b for b in s.schemas if branch_name(b) == name]
        return from_json(b, inner)
    if t in ("float", "double"):
        return float(v)
    return v


def fits(s, v):
    """Whether the decoded Python value v belongs to the union branch s."""
    t = s.type
    if t == "null":
        return v is None
    if t == "boolean":
        return isinstance(v, bool)
    if t in ("int", "long"):
        return isinstance(v, int) and not isinstance(v, bool) or isinstance(
            v, (datetime.date, datetime.time)
        )
    if t in ("float", "double"):
        return isinstance(v, float)
    if t in ("bytes", "fixed"):
        return isinstance(v, (bytes, decimal.Decimal))
    if t == "string":
        return isinstance(v, str)
    if t == "enum":
        return isinstance(v, str) and v in s.symbols
    if t == "array":
        return isinstance(v, list)
    if t in ("record", "error"):
        return isinstance(v, dict) and set(v) == {f.name for f in s.fields}
    if t == "map":
        return isinstance(v, dict)
    return False


def to_json(s, v):
    """The interop JSON value of the decoded Python value v of schema s."""
    lt = logical(s) if not isinstance(s, avro.schema.UnionSchema) else None
    if lt == "date":
        return (v - datetime.date(1970, 1, 1)).days
    if lt in ("time-millis", "time-micros"):
        micros = ((v.hour * 60 + v.minute) * 60 + v.second) * 1000000 + v.microsecond
        return micros // 1000 if lt == "time-millis" else micros
    if lt in ("timestamp-millis", "timestamp-micros"):
        delta = v - EPOCH
        micros = (delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds
        return micros // 1000 if lt == "timestamp-millis" else micros
    if lt == "decimal":
        return format(v, "f")
    t = s.type
    if t in ("bytes", "fixed"):
        return v.hex()
    if t == "array":
        return [to_json(s.items, x) for x in v]
    if t == "map":
        return {k: to_json(s.values, x) for k, x in v.items()}
    if t in ("record", "error"):
        return {f.name: to_json(f.type, v[f.name]) for f in s.fields}
    if t == "union":
        if v is None:
            return None
        b = next(b for b in s.schemas if b.type != "null" and fits(b, v))
        return {branch_name(b): to_json(b, v)}
    return v


def cases():
    return json.loads((ROOT / "tool/interop/cases.json").read_text())["cases"]


def write(out):
    out.mkdir(parents=True, exist_ok=True)
    for case in cases():
        w = load_schema(case["writer"])
        values = [from_json(w, v) for v in case["values"]]
        for codec in ("null", "deflate"):
            with open(out / f"py-{case['name']}-{codec}.avro", "wb") as f:
                writer = avro.datafile.DataFileWriter(f, avro.io.DatumWriter(w), w, codec=codec)
                for v in values:
                    writer.append(v)
                writer.close()
        for i, v in enumerate(values):
            buf = io.BytesIO()
            avro.io.DatumWriter(w).write(v, avro.io.BinaryEncoder(buf))
            (out / f"py-{case['name']}-{i}.bin").write_bytes(buf.getvalue())


def read(directory):
    failures = 0
    for case in cases():
        w = load_schema(case["writer"])
        r = load_schema(case["reader"]) if "reader" in case else w
        expected = case.get("expected", case["values"])
        got = {}
        for codec in ("null", "deflate"):
            with open(directory / f"dart-{case['name']}-{codec}.avro", "rb") as f:
                reader = avro.datafile.DataFileReader(f, avro.io.DatumReader(readers_schema=r))
                got[codec] = [to_json(r, v) for v in reader]
                reader.close()
        got["binary"] = [
            to_json(
                r,
                avro.io.DatumReader(w, r).read(
                    avro.io.BinaryDecoder(
                        io.BytesIO((directory / f"dart-{case['name']}-{i}.bin").read_bytes())
                    )
                ),
            )
            for i in range(len(case["values"]))
        ]
        for kind, values in got.items():
            if values != expected:
                failures += 1
                print(f"FAIL {case['name']} ({kind}): {values} != {expected}")
            else:
                print(f"ok   {case['name']} ({kind})")
    return failures


def main():
    command, directory = sys.argv[1], pathlib.Path(sys.argv[2])
    if command == "write":
        write(directory)
    elif command == "read":
        sys.exit(1 if read(directory) else 0)
    else:
        sys.exit(f"unknown command {command}")


if __name__ == "__main__":
    main()
