#!/usr/bin/env bash
# Regenerates the Dart bindings under bindings/dart/lib/generated/.
#
# Build the ldk-node crate with `--features uniffi` so its proc-macro
# derives expand and emit UNIFFI_META_* symbols + scaffolding into
# libldk_node.{dylib,so}, then run uniffi-dart in library mode against that
# cdylib + the canonical UDL so library-mode metadata merging fills in any
# forward-declared interfaces (e.g. `typedef interface NodeEntropy;`).
#
# Maintainer-only: end users get the committed generated file plus the
# native-assets hook that builds the Rust cdylib on `pub get`.
set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
DART_PKG_DIR="$REPO_ROOT/bindings/dart"
BINDGEN_DIR="$DART_PKG_DIR/rust"
OUT_DIR="$DART_PKG_DIR/lib/generated"
UDL_PATH="$REPO_ROOT/bindings/ldk_node.udl"

case "$(uname -s)" in
	Darwin) LIB_EXT="dylib" ;;
	Linux)  LIB_EXT="so" ;;
	*) echo "Unsupported OS: $(uname -s) (expected Darwin or Linux)"; exit 1 ;;
esac

mkdir -p "$OUT_DIR"

echo "==> Building ldk-node cdylib with --features uniffi..."
cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release --features uniffi

DYNAMIC_LIB_PATH="$REPO_ROOT/target/release/libldk_node.$LIB_EXT"
if [ ! -f "$DYNAMIC_LIB_PATH" ]; then
	echo "Could not find compiled cdylib at $DYNAMIC_LIB_PATH"
	exit 1
fi

echo "==> Generating Dart bindings via uniffi-dart (library mode)..."
(cd "$BINDGEN_DIR" && cargo run --release --bin uniffi-bindgen -- \
	--language dart \
	--out-dir "$OUT_DIR" \
	"$DYNAMIC_LIB_PATH")

echo "==> Patching uniffi-dart code-generation gaps..."
# uniffi-dart v0.2.0+v0.31.1 has two known issues that we patch in place
# here. Remove this block once upstream ships fixes — tracked at
# https://github.com/Uniffi-Dart/uniffi-dart/issues  (file an issue with a
# minimal repro before opening the PR upstream; thread the issue numbers
# into the references below).
#
# 1. Acronym casing inconsistency. Upstream issue: TODO(filed-pre-PR)
#    Type *declarations* use Rust-convention casing
#    (`class Lsps1ChannelInfo`, `class HtlcLocator`, `typedef LspsDateTime`)
#    but *references* inside Optional/Sequence wrappers and method
#    signatures use the original UDL-style all-caps acronym
#    (`LSPS1ChannelInfo`, `HTLCLocator`, `LSPSDateTime`). Result: undefined-
#    name compile errors, plus cascading `num`/`int` mismatches where the
#    undefined refs make arithmetic infer as `dynamic`.
#
# 2. Missing base `[Custom] typedef` for types only used via Optional/Sequence.
#    Upstream issue: TODO(filed-pre-PR)
#    `ScriptBuf` is declared `[Custom] typedef string ScriptBuf;` in the UDL
#    and only referenced through `FfiConverterOptionalScriptBuf`, so
#    uniffi-dart never emits the base `typedef ScriptBuf = String;` and
#    `FfiConverterScriptBuf = FfiConverterString` lines. The Optional
#    wrapper then references undefined names.
GENERATED="$OUT_DIR/ldk_node.dart"
sed -i.bak -E \
	-e 's/LSPS1/Lsps1/g' \
	-e 's/LSPS([A-Z])/Lsps\1/g' \
	-e 's/LSP([A-Z])/Lsp\1/g' \
	-e 's/HTLC([A-Z])/Htlc\1/g' \
	"$GENERATED"
rm -f "${GENERATED}.bak"

# Synthesize the missing ScriptBuf typedef + FfiConverter alias.
# Anchor near the other String-backed Custom typedefs (Mnemonic, etc.).
if ! grep -q '^typedef ScriptBuf = String;' "$GENERATED"; then
	awk '
		/^typedef Mnemonic = String;/ && !done {
			print "typedef ScriptBuf = String;"
			print "typedef FfiConverterScriptBuf = FfiConverterString;"
			done = 1
		}
		{ print }
	' "$GENERATED" > "${GENERATED}.tmp" && mv "${GENERATED}.tmp" "$GENERATED"
fi

echo "==> Regenerating lib/ldk_node.dart umbrella with FFI-internals hide-list..."
GENERATED="$OUT_DIR/ldk_node.dart"
UMBRELLA="$DART_PKG_DIR/lib/ldk_node.dart"

# Collect every top-level identifier that's part of UniFFI's FFI plumbing:
# - FfiConverter*               (per-type lift/lower glue, one per UDL type)
# - Uniffi* / _Uniffi*          (handle maps, vtables, internal errors, foreign-future helpers)
# - RustBuffer / RustCallStatus / ForeignBytes  (FFI struct wrappers)
# - *ErrorHandler               (per-error status decoders)
# We grep for `class`, `final class`, `abstract class`, `enum`, and `typedef`
# declarations matching these patterns. Symbols not in this set form the
# supported public API.
INTERNALS=$(
	grep -hE '^(class|final class|abstract class|enum|typedef) (FfiConverter[A-Za-z0-9_]+|Uniffi[A-Za-z0-9_]+|RustBuffer|RustCallStatus|ForeignBytes|[A-Za-z0-9_]+ErrorHandler)\b' "$GENERATED" \
		| sed -E 's/^(class|final class|abstract class|enum|typedef) ([A-Za-z0-9_]+).*/\2/' \
		| grep -v '^_' \
		| sort -u \
		| paste -sd, -
)
if [ -z "$INTERNALS" ]; then
	echo "warning: hide-list grep produced no matches — umbrella will re-export everything"
fi

cat > "$UMBRELLA" <<EOF
/// Dart bindings for [ldk-node](https://github.com/lightningdevkit/ldk-node),
/// a ready-to-go, self-custodial Lightning Network node library.
///
/// The Rust cdylib is built automatically by Dart's native-assets hook when
/// consumers run \`dart pub get\` / \`flutter pub get\`. Only the symbols
/// re-exported below form the supported public API; UniFFI FFI plumbing
/// emitted into \`lib/generated/\` is hidden from this umbrella and from
/// generated docs (\`dartdoc_options.yaml\` also marks the whole directory
/// \`nodoc\` as a defence-in-depth measure).
///
/// This file is regenerated by \`scripts/uniffi_bindgen_generate_dart.sh\` —
/// edit the script, not this file.
library ldk_node;

export 'generated/ldk_node.dart'
    hide
        ${INTERNALS//,/,
        };
EOF

echo "==> Formatting..."
(cd "$REPO_ROOT" && cargo fmt --all)
if command -v dart >/dev/null 2>&1; then
	dart format "$DART_PKG_DIR/lib" || true
fi

# Sanity-check the regenerated file: if uniffi-dart ever changes the symbols
# we sed-patch (e.g. starts emitting `Lsps1*` everywhere, making our sed a
# no-op, OR starts emitting an `LSPS1ChannelInfo` *class*, which our sed
# would then break), we want CI to fail loudly at regeneration time instead
# of at test-load time.
if command -v dart >/dev/null 2>&1; then
	echo "==> Static-checking generated file + umbrella..."
	# `--no-fatal-warnings`: uniffi-dart emits a couple of unused imports
	# in the generated file; that's cosmetic and not what we're guarding
	# against here. We want errors only (undefined-name, syntax-error,
	# type-mismatch) so a broken sed patch fails CI immediately.
	(cd "$DART_PKG_DIR" && dart analyze --no-fatal-warnings \
		lib/generated/ldk_node.dart lib/ldk_node.dart)
fi

echo "==> Done."
echo "    Generated:  $GENERATED"
echo "    Umbrella:   $UMBRELLA"
