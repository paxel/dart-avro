"""The fastavro side of the benchmark comparison (avro-1036): the cases of tool/bench/bench.dart
that fastavro has, on the same schemas and values.

    pip install "fastavro[snappy,zstandard]==1.13.1"
    python tool/bench/fastavro_bench.py [--json]

Run from the repository root. Every case warms up for 1 s and is then timed for at least 2 s.
Encoding writes fresh bytes per operation, decoding reads a fresh record per operation.
--json also writes the results to fastavro.json in the current directory.
"""

import io
import json
import pathlib
import platform
import sys
import time

import fastavro
from fastavro import json_reader, json_writer, reader, schemaless_reader, schemaless_writer, writer

COMPRESSIONS = ["null", "deflate", "snappy", "zstandard"]
FILE_RECORDS = 1000
WARMUP = 1.0
MEASURE = 2.0

sink = 0


def schema_file(path):
    return fastavro.parse_schema(json.loads(pathlib.Path(path).read_text()))


def measure(op):
    """Microseconds per operation, after the warm-up."""
    end = time.perf_counter() + WARMUP
    while time.perf_counter() < end:
        op()
    ops = 0
    batch = 1
    start = time.perf_counter()
    while True:
        for _ in range(batch):
            op()
        ops += batch
        batch *= 2
        elapsed = time.perf_counter() - start
        if elapsed >= MEASURE:
            return elapsed * 1e6 / ops


def interop_value():
    """The value of interop.avsc, the same on every side."""
    return {
        "intField": 12,
        "longField": 15234324,
        "stringField": "hey",
        "boolField": False,
        "floatField": 1234.0,
        "doubleField": -1234.0,
        "bytesField": b"12312adf",
        "nullField": None,
        "arrayField": [5.0, 0.0, 12.0],
        "mapField": {"a": {"label": "a"}},
        "unionField": 12.0,
        "enumField": "C",
        "fixedField": bytes(range(16)),
        "recordField": {"label": "root", "children": [{"label": "child", "children": []}]},
    }


COLORS = ["RED", "GREEN", "BLUE", "BLACK"]


def wide_field(kind, n):
    return [
        lambda: n * 1000 - 20000,
        lambda: n * 1000000007,
        lambda: f"value-{n}",
        lambda: n * 1.5,
        lambda: n % 2 == 0,
        lambda: n + 0.25,
        lambda: bytes((n + k) & 0xFF for k in range(8)),
        lambda: f"opt-{n}" if (n // 10) % 2 == 0 else None,
        lambda: None if (n // 10) % 2 == 0 else n * 31,
        lambda: COLORS[(n // 10) % 4],
    ][kind]()


def wide_value(r):
    """Record r of wide.avsc: field f<i> of kind i % 10, from n = i + r."""
    return {f"f{i}": wide_field(i % 10, i + r) for i in range(50)}


def longs_value():
    """The 10,000 longs of longs.avsc."""
    return [(j * 2654435761) % (1 << 40) - (1 << 39) for j in range(10000)]


def encode(schema, value):
    out = io.BytesIO()
    schemaless_writer(out, schema, value)
    return out.getvalue()


def cases():
    interop = schema_file("test/data/apache/interop.avsc")
    envelope = schema_file("test/data/axt/types/axt/Envelope.avsc")
    wide = schema_file("tool/bench/schemas/wide.avsc")
    longs = schema_file("tool/bench/schemas/longs.avsc")

    message = bytes.fromhex(pathlib.Path("test/data/axt/memo-message.hex").read_text().strip())
    envelope_value = schemaless_reader(io.BytesIO(message[10:]), envelope)

    workloads = {
        "interop": (interop, "interop-reader.avsc", interop_value()),
        "envelope": (envelope, "envelope-reader.avsc", envelope_value),
        "wide": (wide, "wide-reader.avsc", wide_value(0)),
        "longs": (longs, "longs-reader.avsc", longs_value()),
    }
    out = []
    for name, (schema, reader_file, value) in workloads.items():
        reader_schema = schema_file(f"tool/bench/schemas/{reader_file}")
        data = encode(schema, value)

        def enc(schema=schema, value=value):
            global sink
            sink += len(encode(schema, value))

        def dec(schema=schema, data=data):
            global sink
            sink += schemaless_reader(io.BytesIO(data), schema) is not None

        def res(schema=schema, reader_schema=reader_schema, data=data):
            global sink
            sink += schemaless_reader(io.BytesIO(data), schema, reader_schema) is not None

        out += [
            (f"{name}/encode", len(data), enc),
            (f"{name}/decode", len(data), dec),
            (f"{name}/resolve", len(data), res),
        ]

    # fastavro's JSON encoder recurses without end on the recursive Node of interop.avsc, so
    # only the wide record has JSON cases here.
    for name, schema, value in [("wide", wide, wide_value(0))]:

        def jenc(schema=schema, value=value):
            s = io.StringIO()
            json_writer(s, schema, [value])
            return s.getvalue()

        text = jenc()

        def jdec(schema=schema, text=text):
            global sink
            sink += next(json_reader(io.StringIO(text), schema)) is not None

        def jenc_op(jenc=jenc):
            global sink
            sink += len(jenc())

        size = len(text.rstrip("\n").encode())
        out += [(f"json/{name}/encode", size, jenc_op), (f"json/{name}/decode", size, jdec)]

    records = [wide_value(r) for r in range(FILE_RECORDS)]
    sync = bytes(range(16))
    for compression in COMPRESSIONS:

        def write(compression=compression):
            f = io.BytesIO()
            writer(f, wide, records, codec=compression, sync_interval=64 * 1024, sync_marker=sync)
            return f.getvalue()

        file = write()

        def write_op(write=write):
            global sink
            sink += len(write())

        def read_op(file=file):
            global sink
            sink += sum(1 for _ in reader(io.BytesIO(file)))

        out += [
            (f"file/{compression}/write", len(file), write_op),
            (f"file/{compression}/read", len(file), read_op),
        ]
    return out


def main(args):
    if any(a != "--json" for a in args):
        sys.exit("usage: fastavro_bench.py [--json]")
    json_file = "fastavro.json" if args else None
    results = []
    print(f"{'case':26} {'ops/s':>12} {'µs/op':>12} {'bytes':>9}")
    for name, size, op in cases():
        micros = measure(op)
        results.append({"case": name, "opsPerSecond": 1e6 / micros, "microsPerOp": micros, "bytes": size})
        print(f"{name:26} {1e6 / micros:12.0f} {micros:12.3f} {size:9}", flush=True)
    if json_file:
        pathlib.Path(json_file).write_text(
            json.dumps(
                {
                    "implementation": "fastavro",
                    "fastavro": fastavro.__version__,
                    "python": platform.python_version(),
                    "module": schemaless_reader.__module__,
                    "results": results,
                    "checksum": sink,
                },
                indent=2,
            )
            + "\n"
        )


if __name__ == "__main__":
    main(sys.argv[1:])
