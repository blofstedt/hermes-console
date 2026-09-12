import 'dart:async';
import 'dart:typed_data';

import 'connection_manager.dart';

/// Where the Hermes host publishes a still of the agent's browser screen.
///
/// The agent drives a browser on a virtual display inside the Hermes container
/// and rewrites this file from that display continuously. The dashboard's own
/// authenticated `/api/media` route serves it, so the phone needs nothing new
/// published and no extra credentials to watch the browser.
const String kBrowserLiveSnapshotPath = '/opt/data/browser/live/frame.jpg';

/// Fetches the newest still, or null when there is nothing to show yet.
typedef BrowserSnapshotFetch = Future<Uint8List?> Function();

/// Polls a still of the agent's browser screen and reports each new picture.
///
/// The live-view card has two other picture sources and both are unreliable on
/// a real deployment: the MJPEG stream is published inside the container and is
/// normally unreachable from the phone, and frames embedded in tool results are
/// truncated away by the gateway before the app ever sees them. A still pulled
/// over the dashboard's media route survives both, because the app already
/// holds dashboard credentials for its own API calls.
class BrowserSnapshotPoller {
  /// Pulls one still. Returning null (or empty bytes) is a skipped beat.
  final BrowserSnapshotFetch fetch;

  /// How long to wait between beats.
  final Duration interval;

  /// Ceiling on a single still, so a hostile or broken response cannot make
  /// Android reserve unbounded memory.
  final int maxBytes;

  Timer? _timer;
  bool _inFlight = false;
  int? _lastSignature;
  void Function(Uint8List bytes)? _onFrame;

  BrowserSnapshotPoller({
    required this.fetch,
    this.interval = const Duration(milliseconds: 1500),
    this.maxBytes = 4 * 1024 * 1024,
  });

  /// Polls the dashboard's media route for the still at [path].
  factory BrowserSnapshotPoller.fromDashboard({
    required DashboardClient dashboard,
    String path = kBrowserLiveSnapshotPath,
    Duration interval = const Duration(milliseconds: 1500),
    int maxBytes = 4 * 1024 * 1024,
  }) {
    return BrowserSnapshotPoller(
      interval: interval,
      maxBytes: maxBytes,
      fetch: () async {
        final response = await dashboard.apiDownload(
          'media?path=${Uri.encodeQueryComponent(path)}',
          maxBytes: maxBytes,
          timeout: const Duration(seconds: 15),
        );
        final bytes = response.bytes;
        return bytes.isEmpty ? null : bytes;
      },
    );
  }

  bool get isRunning => _timer != null;

  /// Starts polling, handing every *changed* still to [onFrame].
  ///
  /// Calling this again while running only swaps the callback: rebuilding the
  /// card must not restart the cadence or re-request a picture it already has.
  void start(void Function(Uint8List bytes) onFrame) {
    _onFrame = onFrame;
    if (_timer != null) return;
    // Fire at once — the first picture is what the card is waiting for, and
    // sitting on a full interval first reads as "nothing works".
    unawaited(_beat());
    _timer = Timer.periodic(interval, (_) => unawaited(_beat()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _onFrame = null;
  }

  Future<void> _beat() async {
    // A slow fetch must not stack up behind the timer: skip this beat and let
    // the next one carry the picture.
    if (_inFlight || _onFrame == null) return;
    _inFlight = true;
    try {
      final bytes = await fetch();
      if (bytes == null || bytes.isEmpty) return;
      final signature = _signatureOf(bytes);
      if (signature == _lastSignature) return;
      _lastSignature = signature;
      _onFrame?.call(bytes);
    } catch (_) {
      // A still that is not there yet, a dashboard that is asking to log in, a
      // connection that dropped: all of them are a skipped beat, never an
      // error the user has to see. The card keeps its last picture and the
      // next beat tries again.
    } finally {
      _inFlight = false;
    }
  }

  /// Cheap content fingerprint. The same screen re-encodes to the same bytes,
  /// so a length plus a sample of the payload separates "same picture" from
  /// "the page moved" without paying to hash a megabyte on every beat.
  static int _signatureOf(Uint8List bytes) {
    var hash = bytes.length;
    final step = bytes.length < 64 ? 1 : bytes.length ~/ 32;
    for (var i = 0; i < bytes.length; i += step) {
      hash = (hash * 31 + bytes[i]) & 0x3fffffff;
    }
    return hash;
  }
}
