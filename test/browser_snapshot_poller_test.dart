import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/browser_snapshot_poller.dart';

void main() {
  Uint8List still(int fill, [int length = 128]) =>
      Uint8List.fromList(List<int>.filled(length, fill));

  test('delivers only stills that differ from the one before', () async {
    final a = still(7);
    final b = still(9);
    // The screen sits still for two beats, then moves.
    final script = <Uint8List>[a, a, b, b];
    var beat = 0;
    final seen = <Uint8List>[];

    final poller = BrowserSnapshotPoller(
      interval: const Duration(milliseconds: 10),
      fetch: () async => script[beat < script.length ? beat++ : script.length - 1],
    );
    poller.start(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    poller.stop();

    expect(seen, [a, b]);
  });

  test('a failed, empty or absent still is a skipped beat, not a fault', () async {
    final good = still(3, 64);
    var calls = 0;
    final seen = <Uint8List>[];

    final poller = BrowserSnapshotPoller(
      interval: const Duration(milliseconds: 10),
      fetch: () async {
        calls++;
        if (calls == 1) throw Exception('no still published yet');
        if (calls == 2) return null;
        if (calls == 3) return Uint8List(0);
        return good;
      },
    );
    poller.start(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    poller.stop();

    expect(seen, [good]);
  });

  test('stop() ends polling', () async {
    var calls = 0;
    final poller = BrowserSnapshotPoller(
      interval: const Duration(milliseconds: 10),
      fetch: () async {
        calls++;
        return still(calls);
      },
    );
    poller.start((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    poller.stop();
    final atStop = calls;
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(poller.isRunning, isFalse);
    expect(calls, atStop);
  });

  test('start() while running swaps the callback without re-delivering', () async {
    final poller = BrowserSnapshotPoller(
      interval: const Duration(milliseconds: 10),
      fetch: () async => still(5, 32),
    );
    final first = <Uint8List>[];
    final second = <Uint8List>[];

    poller.start(first.add);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    poller.start(second.add);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    poller.stop();

    // A rebuild must not restart the cadence, and the picture already shown
    // must not be pushed again as if it were new.
    expect(second, isEmpty);
  });
}
