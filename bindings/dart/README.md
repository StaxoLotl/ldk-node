# ldk-node Dart bindings

Dart / Flutter bindings for [ldk-node](https://github.com/lightningdevkit/ldk-node), generated with [uniffi-dart](https://github.com/Uniffi-Dart/uniffi-dart) and built via Dart's [native assets hook](https://dart.dev/interop/c-interop/native-assets).

## For consumers

Add `ldk_node` to your `pubspec.yaml`. The Rust cdylib is compiled automatically by the native assets hook when you run `dart pub get` / `flutter pub get`. A Rust toolchain (1.90+) must be installed on the build machine; cross-compilation targets are listed in `rust/rust-toolchain.toml`.

```dart
import 'package:ldk_node/ldk_node.dart';
```

See `example/basic_example.dart` for usage.

## For maintainers

The generated Dart source under `lib/generated/ldk_node.dart` is **gitignored** and re-exported (with FFI plumbing hidden) from `lib/ldk_node.dart`. Regenerate it whenever `bindings/ldk_node.udl` changes; CI runs the same command:

```sh
./scripts/uniffi_bindgen_generate_dart.sh
```

### Running tests

Smoke tests have no external dependencies:

```sh
cd bindings/dart && dart test test/ldk_node_test.dart
```

The integration test (`test/integration_test.dart`) drives a full Lightning channel-open / pay / close cycle against a regtest stack. The in-tree `tests/docker/docker-compose.yml` is the canonical backend:

```sh
docker compose -p ldk-node -f tests/docker/docker-compose.yml up -d
cd bindings/dart && dart test -r expanded
```

The test honours the standard `BITCOIND_RPC_URL`, `BITCOIND_RPC_USER`, `BITCOIND_RPC_PASSWORD`, and `ESPLORA_ENDPOINT` env vars; defaults match the docker-compose. If the backend isn't reachable the test skips with a one-line message instead of failing.

### Architecture

- **`rust/`** — a thin wrapper crate (`ldk_node_dart`) whose sole job is to produce a cdylib that re-exports `ldk_node` with `features = ["uniffi"]` enabled. ldk-node's own `build.rs` + `uniffi::include_scaffolding!` provides the FFI scaffolding and proc-macro metadata; we don't duplicate any of that here. The crate also hosts a `[[bin]] uniffi-bindgen` that routes `--language dart` through `uniffi-dart` (at `uniffi 0.31.1`) and falls back to upstream `uniffi-bindgen` for other languages.
- **`scripts/uniffi_bindgen_generate_dart.sh`** — builds the `ldk-node` crate with `--features uniffi` and runs the bindgen in **library mode** against `target/release/libldk_node.{dylib,so}` + the canonical `bindings/ldk_node.udl`. Library mode merges proc-macro metadata read out of the cdylib with the UDL graph, so forward-declared types like `typedef interface NodeEntropy;` resolve correctly.
- **`hook/build.dart`** — at consumer `pub get` time, builds the wrapper cdylib via `native_toolchain_rust`'s `RustBuilder`. The cdylib shipped to consumers (`libldk_node_dart.{dylib,so}`) is the artifact `uniffi-dart` generated bindings against.

### Supported platforms

iOS (device + simulator), Android (armv7 / aarch64 / x86_64 / i686), macOS (arm64 + x86_64), Linux (aarch64 + x86_64), Windows (aarch64 + x86_64).
