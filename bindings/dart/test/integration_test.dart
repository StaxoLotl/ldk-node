// Full-stack integration test for `channel_full_cycle` against any
// Esplora-REST-compatible regtest stack.
//
// Defaults match the in-tree `tests/docker/docker-compose.yml` so it runs
// with no overrides:
//
//   docker compose -p ldk-node -f tests/docker/docker-compose.yml up -d
//   cd bindings/dart && dart test -r expanded
//
// Override the endpoints to run against a different backend:
//   BITCOIND_RPC_URL       default http://127.0.0.1:18443
//   BITCOIND_RPC_USER      default user
//   BITCOIND_RPC_PASSWORD  default pass
//   ESPLORA_ENDPOINT       default http://127.0.0.1:3002
//
// The test skips itself with a clear message if the stack isn't reachable.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ldk_node/ldk_node.dart';
import 'package:test/test.dart';

final _bitcoindRpcUrl =
    Platform.environment['BITCOIND_RPC_URL'] ?? 'http://127.0.0.1:18443';
final _bitcoindUser = Platform.environment['BITCOIND_RPC_USER'] ?? 'user';
final _bitcoindPass = Platform.environment['BITCOIND_RPC_PASSWORD'] ?? 'pass';
final _esploraUrl =
    Platform.environment['ESPLORA_ENDPOINT'] ?? 'http://127.0.0.1:3002';

void main() {
  group('channel full cycle', () {
    test('open → pay → close', () async {
      // Skip with a clear hint instead of failing with a cryptic
      // connection-refused later. `markTestSkipped` only takes effect
      // inside a test body, not from setUpAll, hence this layout.
      final reason = await _backendUnreachableReason();
      if (reason != null) {
        markTestSkipped(reason);
        return;
      }

      _log('Using bitcoind=$_bitcoindRpcUrl  esplora=$_esploraUrl');
      await _ensureWalletLoaded();
      // Premine if the wallet hasn't built up spendable coins yet. 101
      // blocks gets the first coinbase past maturity.
      final balance = (await _bitcoindRpc('getbalance', [])) as num;
      if (balance < 1) {
        _log('premining 101 blocks (wallet balance was $balance)');
        await _mine(101);
      }

      final nodeA = await NodeHandle.build('a');
      final nodeB = await NodeHandle.build('b');
      addTearDown(nodeA.dispose);
      addTearDown(nodeB.dispose);

      nodeA.handle.start();
      nodeB.handle.start();
      _log('node A id=${_short(nodeA.handle.nodeId())}  listening=${nodeA.handle.listeningAddresses()?.first}');
      _log('node B id=${_short(nodeB.handle.nodeId())}  listening=${nodeB.handle.listeningAddresses()?.first}');

      // --- Fund node A on-chain ---
      // Send 1 BTC to A's wallet, mine 6 confs, then poll until A's
      // on-chain balance reflects the funding. The retry loop covers
      // electrs's indexing lag — without it, A's first `syncWallets()`
      // races the block ingestion and `openChannel` fails with
      // `NodeException.insufficientFunds`.
      final addrA = nodeA.handle.onchainPayment().newAddress();
      _log('funding A → sending 1 BTC to $addrA');
      final fundingTxid = await _bitcoindRpc('sendtoaddress', [addrA, 1.0]) as String;
      _log('  funding txid=${_short(fundingTxid)}');
      await _mine(6);
      final spendable = await _eventually(
        () async {
          nodeA.handle.syncWallets();
          final s = nodeA.handle.listBalances().spendableOnchainBalanceSats;
          return s >= 110000 ? s : null;
        },
        timeout: const Duration(seconds: 30),
        description: "A's wallet sees >= 110k sats spendable",
      );
      _log("A funded: spendable=${spendable} sats");

      // --- Open a 100k sat channel A → B ---
      final bListening = nodeB.handle.listeningAddresses();
      expect(bListening, isNotNull);
      expect(bListening!, isNotEmpty);
      _log('opening channel A → B  amount=100_000 sats');
      final userChannelId = nodeA.handle.openChannel(
        nodeId: nodeB.handle.nodeId(),
        address: bListening.first,
        channelAmountSats: 100000,
        pushToCounterpartyMsat: null,
        channelConfig: null,
      );
      _log('  user_channel_id=${_short(userChannelId)}');

      final readyA = await _eventually<ChannelReadyEvent>(
        () async {
          await _mine(1);
          nodeA.handle.syncWallets();
          nodeB.handle.syncWallets();
          return nodeA.drainUntil<ChannelReadyEvent>(
            within: const Duration(seconds: 2),
          );
        },
        timeout: const Duration(seconds: 60),
        description: 'A sees ChannelReady',
      );
      _log('A: ChannelReady channel_id=${_short(readyA.channelId)}');
      final readyB = await _eventually<ChannelReadyEvent>(
        () async => nodeB.drainUntil<ChannelReadyEvent>(
          within: const Duration(seconds: 2),
        ),
        timeout: const Duration(seconds: 30),
        description: 'B sees ChannelReady',
      );
      _log('B: ChannelReady channel_id=${_short(readyB.channelId)}');

      // --- Pay 1M msat A → B ---
      _log('B → issuing 1_000_000 msat BOLT11 invoice');
      final invoice = nodeB.handle.bolt11Payment().receive(
        amountMsat: 1000000,
        description: DirectBolt11InvoiceDescription('integration test'),
        expirySecs: 600,
      );
      final paymentId = nodeA.handle.bolt11Payment().send(
        invoice: invoice,
        routeParameters: null,
      );
      _log('A → sent  payment_id=${_short(paymentId)}');

      final received = await _eventually<PaymentReceivedEvent>(
        () async => nodeB.drainUntil<PaymentReceivedEvent>(
          within: const Duration(seconds: 2),
        ),
        timeout: const Duration(seconds: 30),
        description: 'B sees PaymentReceived',
      );
      _log('B: PaymentReceived amount=${received.amountMsat} msat');
      final success = await _eventually<PaymentSuccessfulEvent>(
        () async => nodeA.drainUntil<PaymentSuccessfulEvent>(
          within: const Duration(seconds: 2),
        ),
        timeout: const Duration(seconds: 30),
        description: 'A sees PaymentSuccessful',
      );
      _log('A: PaymentSuccessful fee_paid=${success.feePaidMsat ?? 0} msat');

      // --- Cooperative close ---
      _log('A → closing channel cooperatively');
      nodeA.handle.closeChannel(
        userChannelId: userChannelId,
        counterpartyNodeId: nodeB.handle.nodeId(),
      );
      final closed = await _eventually<ChannelClosedEvent>(
        () async {
          await _mine(1);
          nodeA.handle.syncWallets();
          nodeB.handle.syncWallets();
          return nodeA.drainUntil<ChannelClosedEvent>(
            within: const Duration(seconds: 2),
          );
        },
        timeout: const Duration(seconds: 60),
        description: 'A sees ChannelClosed',
      );
      _log('A: ChannelClosed channel_id=${_short(closed.channelId)}');

      nodeA.handle.stop();
      nodeB.handle.stop();
      _log('done.');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

// --------------------------------------------------------------------------
// Backend reachability helpers
// --------------------------------------------------------------------------

const _startBackendHint =
    'Start the regtest stack with: '
    'docker compose -p ldk-node -f tests/docker/docker-compose.yml up -d';

Future<String?> _backendUnreachableReason() async {
  try {
    await _bitcoindRpc('getblockchaininfo', []);
  } catch (e) {
    return 'bitcoind RPC unreachable at $_bitcoindRpcUrl ($e). $_startBackendHint';
  }
  try {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('$_esploraUrl/blocks/tip/height'),
      );
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode >= 400) {
        return 'Esplora returned ${res.statusCode} at $_esploraUrl/blocks/tip/height';
      }
    } finally {
      client.close(force: true);
    }
  } catch (e) {
    return 'Esplora unreachable at $_esploraUrl ($e). $_startBackendHint';
  }
  return null;
}

/// Modern bitcoind (>= 0.21) doesn't auto-create a default wallet. Try to
/// load it; if it doesn't exist, create it. If it's already loaded, ignore
/// the "already loaded" error.
Future<void> _ensureWalletLoaded() async {
  try {
    await _bitcoindRpc('loadwallet', ['']);
  } catch (e) {
    // -18 = wallet file does not exist → create it.
    // -35 = wallet already loaded → fine.
    if (e.toString().contains('-18')) {
      await _bitcoindRpc('createwallet', ['']);
    } else if (!e.toString().contains('-35')) {
      rethrow;
    }
  }
}

Future<void> _mine(int blocks) async {
  final addr = await _bitcoindRpc('getnewaddress', []) as String;
  await _bitcoindRpc('generatetoaddress', [blocks, addr]);
}

Future<dynamic> _bitcoindRpc(String method, List<Object?> params) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$_bitcoindRpcUrl/'));
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('$_bitcoindUser:$_bitcoindPass'))}',
    );
    req.headers.contentType = ContentType('application', 'json');
    req.add(
      utf8.encode(
        jsonEncode({
          'jsonrpc': '1.0',
          'id': 'ldk-dart',
          'method': method,
          'params': params,
        }),
      ),
    );
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    if (decoded['error'] != null) {
      throw StateError('bitcoind RPC $method: ${decoded['error']}');
    }
    return decoded['result'];
  } finally {
    client.close(force: true);
  }
}

class NodeHandle {
  NodeHandle._(this.handle, this.storageDir);

  final Node handle;
  final Directory storageDir;
  final List<Event> _pending = [];

  static Future<NodeHandle> build(String label) async {
    final storage = Directory.systemTemp.createTempSync(
      'ldk_dart_node_${label}_',
    );
    // Ask the OS for a free port for this node to listen on.
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    await socket.close();

    final builder = Builder();
    try {
      builder.setNetwork(network: Network.regtest);
      builder.setStorageDirPath(storageDirPath: storage.path);
      builder.setListeningAddresses(listeningAddresses: ['127.0.0.1:$port']);
      builder.setChainSourceEsplora(serverUrl: _esploraUrl, config: null);
      final entropy = NodeEntropy.fromBip39Mnemonic(
        mnemonic: generateEntropyMnemonic(wordCount: WordCount.words12),
        passphrase: null,
      );
      try {
        return NodeHandle._(builder.build(nodeEntropy: entropy), storage);
      } finally {
        entropy.dispose();
      }
    } finally {
      builder.dispose();
    }
  }

  /// Drains queued events and returns the first matching `T`, or `null` if
  /// none arrives within `within`. Non-matching events are buffered so
  /// later `drainUntil` calls can still find them.
  T? drainUntil<T extends Event>({required Duration within}) {
    for (var i = 0; i < _pending.length; i++) {
      if (_pending[i] is T) return _pending.removeAt(i) as T;
    }
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      final ev = handle.nextEvent();
      if (ev == null) {
        sleep(const Duration(milliseconds: 100));
        continue;
      }
      handle.eventHandled();
      if (ev is T) return ev;
      _pending.add(ev);
    }
    return null;
  }

  void dispose() {
    try {
      handle.stop();
    } catch (_) {}
    handle.dispose();
    try {
      storageDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Print a milestone marker. Use `dart test -r expanded` to surface these
/// for passing tests (the default compact reporter swallows print output).
void _log(String msg) {
  print('[ldk-test] $msg');
}

/// Truncates long hex/identifier strings for readable progress logs.
String _short(String s) => s.length <= 16 ? s : '${s.substring(0, 8)}…${s.substring(s.length - 4)}';

Future<T> _eventually<T>(
  Future<T?> Function() op, {
  required Duration timeout,
  required String description,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = await op();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw TimeoutException('Timed out waiting: $description', timeout);
}
