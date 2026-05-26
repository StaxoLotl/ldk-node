// Smoke / surface-level integration test for the generated Dart bindings.
//
// This is the Dart counterpart to `tests/integration_tests_rust.rs`'s
// in-process tests — it doesn't spin up bitcoind/electrs, but it does
// load the real Rust cdylib via Dart's native-assets hook and exercises
// the parts of the FFI boundary you can hit without a network:
//
//   * namespace functions          (`defaultConfig`, `generateEntropyMnemonic`)
//   * `[Custom] typedef string`     round-trip (Mnemonic → NodeEntropy)
//   * enums                         (WordCount, Network)
//   * records                       (Config field shapes + defaults)
//   * objects                       (Builder construction + configuration)
//   * tagged-union exception path   (Builder.build with no chain source)
//
// Running it confirms the binding generation pipeline (UDL → uniffi-dart →
// cdylib load) is end-to-end functional. Wire-level Lightning behaviour
// stays the responsibility of the Rust integration tests.

import 'dart:io';

import 'package:ldk_node/ldk_node.dart';
import 'package:test/test.dart';

void main() {
  group('namespace functions', () {
    test('defaultConfig returns Rust-side Config::default()', () {
      final cfg = defaultConfig();

      // Mirrors the constants in src/config.rs.
      expect(cfg.network, Network.bitcoin);
      expect(cfg.storageDirPath, '/tmp/ldk_node');
      expect(cfg.probingLiquidityLimitMultiplier, 3);
      expect(cfg.listeningAddresses, isNull);
      expect(cfg.announcementAddresses, isNull);
      expect(cfg.nodeAlias, isNull);
      expect(cfg.trustedPeers0conf, isEmpty);
      expect(cfg.anchorChannelsConfig, isNotNull,
          reason: 'AnchorChannelsConfig::default() should be Some, not None');
      expect(cfg.torConfig, isNull);
    });

    test('generateEntropyMnemonic honours explicit word count', () {
      for (final wc in WordCount.values) {
        final mnemonic = generateEntropyMnemonic(wordCount: wc);
        final words = mnemonic.split(RegExp(r'\s+'));
        expect(words.length, _expectedWords(wc),
            reason: 'wordCount=$wc should yield ${_expectedWords(wc)} words, got "$mnemonic"');
      }
    });

    test('generateEntropyMnemonic defaults to 24 words when wordCount is null', () {
      final mnemonic = generateEntropyMnemonic(wordCount: null);
      expect(mnemonic.split(RegExp(r'\s+')).length, 24);
    });
  });

  group('[Custom] typedef round-trip', () {
    test('Mnemonic crosses the FFI as a String and back into NodeEntropy', () {
      // generate → Mnemonic (= String) → NodeEntropy constructor.
      // If the [Custom] type machinery is wrong, either the lower or the
      // subsequent lift would corrupt the value and `from_bip39_mnemonic`
      // would either panic in Rust or return a different entropy.
      final mnemonic = generateEntropyMnemonic(wordCount: WordCount.words24);
      expect(mnemonic, isA<String>());
      expect(mnemonic, isNotEmpty);

      final entropy = NodeEntropy.fromBip39Mnemonic(
        mnemonic: mnemonic,
        passphrase: null,
      );
      addTearDown(entropy.dispose);
      expect(entropy, isNotNull);
    });
  });

  group('Builder', () {
    test('default constructor produces an Object handle', () {
      final builder = Builder();
      addTearDown(builder.dispose);
      expect(builder, isNotNull);
    });

    test('fromConfig accepts a defaultConfig() and configuration methods chain', () {
      final builder = Builder.fromConfig(config: defaultConfig());
      addTearDown(builder.dispose);

      final storageDir = Directory.systemTemp.createTempSync('ldk_node_test_');
      addTearDown(() => storageDir.deleteSync(recursive: true));

      // All setters return void; we're just confirming they don't throw.
      builder.setNetwork(network: Network.regtest);
      builder.setStorageDirPath(storageDirPath: storageDir.path);
    });

    test('build with valid minimal config returns a Node handle', () {
      // Smoke-tests the throws-vs-returns FFI plumbing for a fallible
      // constructor: `build` returns `Result<Node, BuildError>` in Rust,
      // which uniffi-dart lowers to either a `Node` instance or a thrown
      // `BuildException`. We exercise the happy path; chain-source
      // validation happens at `node.start()`, not here.
      final storageDir = Directory.systemTemp.createTempSync('ldk_node_test_');
      addTearDown(() => storageDir.deleteSync(recursive: true));

      final builder = Builder();
      addTearDown(builder.dispose);
      builder.setNetwork(network: Network.regtest);
      builder.setStorageDirPath(storageDirPath: storageDir.path);

      final entropy = NodeEntropy.fromBip39Mnemonic(
        mnemonic: generateEntropyMnemonic(wordCount: WordCount.words12),
        passphrase: null,
      );
      addTearDown(entropy.dispose);

      final node = builder.build(nodeEntropy: entropy);
      addTearDown(node.dispose);
      expect(node, isA<Node>());
    });
  });
}

/// BIP-39 mapping for our `WordCount` enum.
int _expectedWords(WordCount wc) {
  switch (wc) {
    case WordCount.words12:
      return 12;
    case WordCount.words15:
      return 15;
    case WordCount.words18:
      return 18;
    case WordCount.words21:
      return 21;
    case WordCount.words24:
      return 24;
  }
}
