# AXT examples

Copied from the AXT specification, https://github.com/paxel/axt, release v0.1.0, `spec/envelope.md`,
section 10, and its vectors (`vectors/keys/keys.json`, `vectors/file/file.json`), which are dedicated to the public domain (CC0 1.0). Its bytes were written by
fastavro 1.13.1, a second Avro implementation.

| File                      | Content                                                                     |
|---------------------------|-----------------------------------------------------------------------------|
| `envelope-canonical.json` | The Parsing Canonical Form of `axt.Envelope`, format 1                      |
| `memo-canonical.json`     | The Parsing Canonical Form of `com.example.Memo`                            |
| `memo-message.hex`        | The message of section 10.2, 210 bytes, as hexadecimal                      |
| `memo-file.hex`           | The file of section 10.3, 5,020 bytes, as hexadecimal                       |
| `types/`                  | The 29 `.avsc` files of `types/` of release v0.1.0, unchanged, also CC0 1.0 |
| `axt_types.g.dart`        | The classes generated from `types/`                                         |

`axt_types.g.dart` is written from the repository root by:

```sh
dart run avro:generate test/data/axt/types --prefix axt=Axt --prefix axt.example.v1=AxtExample -o test/data/axt/axt_types.g.dart
```

`test/axt_types_test.dart` fails when the file is not what this command writes.
