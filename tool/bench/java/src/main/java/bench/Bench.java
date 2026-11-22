// The Java side of the benchmark comparison (avro-1036): the cases of tool/bench/bench.dart,
// with Apache Avro 1.12.1's generic reader and writer, on the same schemas and values.
//
//   cd tool/bench/java
//   mvn -q -T1 package dependency:copy-dependencies
//   cd ../../..
//   java -cp 'tool/bench/java/target/classes:tool/bench/java/target/dependency/*' bench.Bench [--json FILE]
//
// Run from the repository root. Every case runs for 2 s to warm up the JIT, then is timed for
// at least 2 s. Encoding writes a fresh byte[] per operation; decoding reads a fresh record per
// operation (no object reuse), with the reader's defaults: strings decode as Utf8.

package bench;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.apache.avro.Schema;
import org.apache.avro.file.CodecFactory;
import org.apache.avro.file.DataFileReader;
import org.apache.avro.file.DataFileWriter;
import org.apache.avro.file.SeekableByteArrayInput;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericDatumReader;
import org.apache.avro.generic.GenericDatumWriter;
import org.apache.avro.generic.GenericRecord;
import org.apache.avro.io.BinaryDecoder;
import org.apache.avro.io.BinaryEncoder;
import org.apache.avro.io.DecoderFactory;
import org.apache.avro.io.EncoderFactory;
import org.apache.avro.io.JsonDecoder;
import org.apache.avro.io.JsonEncoder;

public final class Bench {
  static final String[] COMPRESSIONS = {"null", "deflate", "snappy", "zstandard"};
  static final int FILE_RECORDS = 1000;
  static final long WARMUP_NANOS = 2_000_000_000L;
  static final long MEASURE_NANOS = 2_000_000_000L;

  /** Where results go so that no operation can be optimised away. */
  static long sink;

  /** The last decoded value, kept for the same reason, without walking it. */
  static Object last;

  interface Op {
    void run() throws IOException;
  }

  record Case(String name, int bytes, Op op) {}

  public static void main(String[] args) throws IOException {
    String jsonFile = null;
    for (int i = 0; i < args.length; i++) {
      if (args[i].equals("--json") && i + 1 < args.length) jsonFile = args[++i];
    }
    StringBuilder json = new StringBuilder();
    json.append("{\n  \"implementation\": \"java\",\n  \"java\": \"")
        .append(System.getProperty("java.vm.name")).append(' ')
        .append(System.getProperty("java.runtime.version"))
        .append("\",\n  \"results\": [");
    System.out.printf("%-26s %12s %12s %9s%n", "case", "ops/s", "µs/op", "bytes");
    boolean first = true;
    for (Case c : cases()) {
      double micros = measure(c.op());
      System.out.printf(Locale.ROOT, "%-26s %12.0f %12.3f %9d%n", c.name(), 1e6 / micros, micros, c.bytes());
      json.append(first ? "\n" : ",\n").append(String.format(Locale.ROOT,
          "    {\"case\": \"%s\", \"opsPerSecond\": %.1f, \"microsPerOp\": %.4f, \"bytes\": %d}",
          c.name(), 1e6 / micros, micros, c.bytes()));
      first = false;
    }
    json.append("\n  ],\n  \"checksum\": ").append(sink).append("\n}\n");
    if (jsonFile != null) Files.writeString(Path.of(jsonFile), json.toString());
  }

  /** Microseconds per operation, after the warm-up. */
  static double measure(Op op) throws IOException {
    long end = System.nanoTime() + WARMUP_NANOS;
    while (System.nanoTime() < end) op.run();
    long ops = 0;
    long batch = 1;
    long start = System.nanoTime();
    long elapsed;
    do {
      for (long i = 0; i < batch; i++) op.run();
      ops += batch;
      batch *= 2;
      elapsed = System.nanoTime() - start;
    } while (elapsed < MEASURE_NANOS);
    return elapsed / 1e3 / ops;
  }

  static Schema schemaFile(String path) throws IOException {
    return new Schema.Parser().parse(Files.readString(Path.of(path)));
  }

  static List<Case> cases() throws IOException {
    Schema interop = schemaFile("test/data/apache/interop.avsc");
    Schema envelope = schemaFile("test/data/axt/types/axt/Envelope.avsc");
    Schema wide = schemaFile("tool/bench/schemas/wide.avsc");
    Schema longs = schemaFile("tool/bench/schemas/longs.avsc");

    byte[] message = hexFile("test/data/axt/memo-message.hex");
    GenericRecord envelopeValue = new GenericDatumReader<GenericRecord>(envelope)
        .read(null, DecoderFactory.get().binaryDecoder(message, 10, message.length - 10, null));
    // A String, as the other sides encode it, not the Utf8 the reader decoded.
    GenericRecord ref = (GenericRecord) envelopeValue.get("record");
    ref.put("id", ref.get("id").toString());

    Map<String, Object[]> workloads = new LinkedHashMap<>();
    workloads.put("interop", new Object[] {interop, "interop-reader.avsc", interopValue(interop)});
    workloads.put("envelope", new Object[] {envelope, "envelope-reader.avsc", envelopeValue});
    workloads.put("wide", new Object[] {wide, "wide-reader.avsc", wideValue(wide, 0)});
    workloads.put("longs", new Object[] {longs, "longs-reader.avsc", longsValue()});

    List<Case> list = new ArrayList<>();
    for (Map.Entry<String, Object[]> w : workloads.entrySet()) {
      String name = w.getKey();
      Schema schema = (Schema) w.getValue()[0];
      Schema reader = schemaFile("tool/bench/schemas/" + w.getValue()[1]);
      Object value = w.getValue()[2];
      Binary binary = new Binary(schema, reader);
      byte[] bytes = binary.encode(value);
      list.add(new Case(name + "/encode", bytes.length, () -> sink += binary.encode(value).length));
      list.add(new Case(name + "/decode", bytes.length, () -> last = binary.decode(bytes)));
      list.add(new Case(name + "/resolve", bytes.length, () -> last = binary.resolve(bytes)));
    }

    for (Object[] w : new Object[][] {
        {"interop", interop, interopValue(interop)}, {"wide", wide, wideValue(wide, 0)}}) {
      String name = (String) w[0];
      Json codec = new Json((Schema) w[1]);
      Object value = w[2];
      String text = codec.encode(value);
      int size = text.getBytes(StandardCharsets.UTF_8).length;
      list.add(new Case("json/" + name + "/encode", size, () -> sink += codec.encode(value).length()));
      list.add(new Case("json/" + name + "/decode", size, () -> last = codec.decode(text)));
    }

    List<GenericRecord> records = new ArrayList<>();
    for (int r = 0; r < FILE_RECORDS; r++) records.add(wideValue(wide, r));
    byte[] sync = new byte[16];
    for (int i = 0; i < 16; i++) sync[i] = (byte) i;
    for (String compression : COMPRESSIONS) {
      byte[] file = writeFile(wide, records, compression, sync);
      list.add(new Case("file/" + compression + "/write", file.length,
          () -> sink += writeFile(wide, records, compression, sync).length));
      list.add(new Case("file/" + compression + "/read", file.length, () -> sink += readFile(file)));
    }
    return list;
  }

  /** The generic writer and readers of one schema, reusing their encoder and decoder. */
  static final class Binary {
    final GenericDatumWriter<Object> writer;
    final GenericDatumReader<Object> plain;
    final GenericDatumReader<Object> resolving;
    final ByteArrayOutputStream out = new ByteArrayOutputStream();
    BinaryEncoder encoder;
    BinaryDecoder decoder;

    Binary(Schema schema, Schema reader) {
      writer = new GenericDatumWriter<>(schema);
      plain = new GenericDatumReader<>(schema);
      resolving = new GenericDatumReader<>(schema, reader);
    }

    byte[] encode(Object value) throws IOException {
      out.reset();
      encoder = EncoderFactory.get().binaryEncoder(out, encoder);
      writer.write(value, encoder);
      encoder.flush();
      return out.toByteArray();
    }

    Object decode(byte[] bytes) throws IOException {
      decoder = DecoderFactory.get().binaryDecoder(bytes, decoder);
      return plain.read(null, decoder);
    }

    Object resolve(byte[] bytes) throws IOException {
      decoder = DecoderFactory.get().binaryDecoder(bytes, decoder);
      return resolving.read(null, decoder);
    }
  }

  /** The JSON encoding of one schema, reusing its encoder and decoder. */
  static final class Json {
    final GenericDatumWriter<Object> writer;
    final GenericDatumReader<Object> reader;
    final ByteArrayOutputStream out = new ByteArrayOutputStream();
    final JsonEncoder encoder;
    final JsonDecoder decoder;

    Json(Schema schema) throws IOException {
      writer = new GenericDatumWriter<>(schema);
      reader = new GenericDatumReader<>(schema);
      encoder = EncoderFactory.get().jsonEncoder(schema, out);
      decoder = DecoderFactory.get().jsonDecoder(schema, "null");
    }

    String encode(Object value) throws IOException {
      out.reset();
      encoder.configure(out);
      writer.write(value, encoder);
      encoder.flush();
      return out.toString(StandardCharsets.UTF_8);
    }

    Object decode(String text) throws IOException {
      decoder.configure(text);
      return reader.read(null, decoder);
    }
  }

  static CodecFactory codec(String compression) {
    return switch (compression) {
      case "null" -> CodecFactory.nullCodec();
      case "deflate" -> CodecFactory.deflateCodec(6);
      case "snappy" -> CodecFactory.snappyCodec();
      case "zstandard" -> CodecFactory.zstandardCodec(3, true);
      default -> throw new IllegalArgumentException(compression);
    };
  }

  static byte[] writeFile(Schema schema, List<GenericRecord> records, String compression, byte[] sync)
      throws IOException {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    try (DataFileWriter<GenericRecord> writer = new DataFileWriter<>(new GenericDatumWriter<>(schema))) {
      writer.setCodec(codec(compression));
      writer.setSyncInterval(64 * 1024);
      writer.create(schema, out, sync);
      for (GenericRecord r : records) writer.append(r);
    }
    return out.toByteArray();
  }

  static int readFile(byte[] file) throws IOException {
    int n = 0;
    try (DataFileReader<Object> reader =
        new DataFileReader<>(new SeekableByteArrayInput(file), new GenericDatumReader<>())) {
      while (reader.hasNext()) {
        reader.next(null);
        n++;
      }
    }
    return n;
  }

  static byte[] hexFile(String path) throws IOException {
    String hex = Files.readString(Path.of(path)).trim();
    byte[] bytes = new byte[hex.length() / 2];
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
    }
    return bytes;
  }

  /** The value of interop.avsc, the same on every side. */
  static GenericRecord interopValue(Schema schema) {
    Schema foo = schema.getField("mapField").schema().getValueType();
    Schema node = schema.getField("recordField").schema();
    GenericRecord a = new GenericData.Record(foo);
    a.put("label", "a");
    Map<String, Object> map = new HashMap<>();
    map.put("a", a);
    byte[] fixed = new byte[16];
    for (int i = 0; i < 16; i++) fixed[i] = (byte) i;
    GenericRecord child = new GenericData.Record(node);
    child.put("label", "child");
    child.put("children", new ArrayList<>());
    GenericRecord root = new GenericData.Record(node);
    root.put("label", "root");
    root.put("children", List.of(child));

    GenericRecord r = new GenericData.Record(schema);
    r.put("intField", 12);
    r.put("longField", 15234324L);
    r.put("stringField", "hey");
    r.put("boolField", false);
    r.put("floatField", 1234.0f);
    r.put("doubleField", -1234.0);
    r.put("bytesField", ByteBuffer.wrap("12312adf".getBytes(StandardCharsets.UTF_8)));
    r.put("nullField", null);
    r.put("arrayField", List.of(5.0, 0.0, 12.0));
    r.put("mapField", map);
    r.put("unionField", 12.0);
    r.put("enumField", new GenericData.EnumSymbol(schema.getField("enumField").schema(), "C"));
    r.put("fixedField", new GenericData.Fixed(schema.getField("fixedField").schema(), fixed));
    r.put("recordField", root);
    return r;
  }

  static final String[] COLORS = {"RED", "GREEN", "BLUE", "BLACK"};

  /** Record r of wide.avsc: field f<i> of kind i % 10, from n = i + r. */
  static GenericRecord wideValue(Schema schema, int r) {
    Schema color = schema.getField("f9").schema();
    GenericRecord record = new GenericData.Record(schema);
    for (int i = 0; i < 50; i++) {
      int n = i + r;
      Object v = switch (i % 10) {
        case 0 -> n * 1000 - 20000;
        case 1 -> n * 1000000007L;
        case 2 -> "value-" + n;
        case 3 -> n * 1.5;
        case 4 -> n % 2 == 0;
        case 5 -> n + 0.25f;
        case 6 -> {
          byte[] b = new byte[8];
          for (int k = 0; k < 8; k++) b[k] = (byte) ((n + k) & 0xff);
          yield ByteBuffer.wrap(b);
        }
        case 7 -> (n / 10) % 2 == 0 ? "opt-" + n : null;
        case 8 -> (n / 10) % 2 == 0 ? null : n * 31L;
        default -> new GenericData.EnumSymbol(color, COLORS[(n / 10) % 4]);
      };
      record.put("f" + i, v);
    }
    return record;
  }

  /** The 10,000 longs of longs.avsc. */
  static List<Long> longsValue() {
    List<Long> list = new ArrayList<>(10000);
    for (long j = 0; j < 10000; j++) list.add((j * 2654435761L) % (1L << 40) - (1L << 39));
    return list;
  }
}
