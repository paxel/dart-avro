# Container files and blocks in the optional compressions

Generated for this package, not copied from elsewhere.

| File                     | What it is                                                                                                                                       |
|--------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `weather-bzip2.avro`     | The records of `../apache/weather.avro`, written by Python avro with `bzip2`                                                                     |
| `weather-zstandard.avro` | The same, written by Python avro with `zstandard`                                                                                                |
| `weather-xz.avro`        | The same in one block, an xz stream from Python's `lzma`, the file built by hand                                                                 |
| `bomb-bzip2.bin`         | 200 MiB of zero bytes, compressed by Python's `bz2.compress(data, 9)`                                                                            |
| `bomb-xz.bin`            | The same, by `lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64)`                                                                |
| `bomb-xz-x86.bin`        | 20 MiB of zero bytes, by `lzma.compress(data, format=lzma.FORMAT_XZ, filters=[{"id": lzma.FILTER_X86}, {"id": lzma.FILTER_LZMA2, "preset": 6}])` |
| `bomb-xz-sizes.bin`      | 20 MiB of zero bytes, by `xz -T2 --block-size=4194304` (XZ Utils 5.8.1), whose block headers declare their sizes                                 |
| `bomb-zstandard.bin`     | The same, by `zstandard.ZstdCompressor(level=19).compress(data)`                                                                                 |

The weather files come from `python3 write_weather.py ../apache/weather.avro .`, with Python
3.13.5, avro 1.12.2 and zstandard 0.25.0. Python avro 1.12.2 has no `xz` codec, so the script
builds that file itself, the way Java's `XZCodec` compresses a block.
