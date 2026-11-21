# Writes weather.avro's records as bzip2 and zstandard files with avro's DataFileWriter, and
# as an xz file built by hand (avro 1.12.2 for Python has no xz codec), its one block an xz
# stream from Python's lzma, as Java's XZCodec writes it.
import io, lzma, sys, avro.datafile, avro.io
src, out = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    r = avro.datafile.DataFileReader(f, avro.io.DatumReader())
    schema = r.datum_reader.writers_schema
    schema_text = r.get_meta("avro.schema")
    records = list(r)
for codec in ("bzip2", "zstandard"):
    with open(f"{out}/weather-{codec}.avro", "wb") as f:
        w = avro.datafile.DataFileWriter(f, avro.io.DatumWriter(), schema, codec=codec)
        for rec in records:
            w.append(rec)
        w.close()
raw = io.BytesIO()
enc = avro.io.BinaryEncoder(raw)
for rec in records:
    avro.io.DatumWriter(schema).write(rec, enc)
block = lzma.compress(raw.getvalue(), format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64)
sync = bytes(range(16))
f = io.BytesIO()
e = avro.io.BinaryEncoder(f)
f.write(b"Obj\x01")
e.write_long(2)
e.write_utf8("avro.codec"); e.write_bytes(b"xz")
e.write_utf8("avro.schema"); e.write_bytes(schema_text)
e.write_long(0)
f.write(sync)
e.write_long(len(records)); e.write_bytes(block); f.write(sync)
open(f"{out}/weather-xz.avro", "wb").write(f.getvalue())
