import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/browser_stream_client.dart';
import '../theme/app_theme.dart';

/// The browser's screen as it moves, for the card that otherwise shows stills.
///
/// Takes the addresses the stream might live at and works through them in
/// order, keeping the first that produces a frame. The server publishes the
/// feed, but WHERE it comes out is decided by the deployment's own packaging
/// — a reverse-proxy route, a forwarded port — so a single hardcoded address
/// would be wrong for most installs. Trying is cheap; guessing is not.
///
/// Failure is quiet by design: [onUnavailable] fires once the candidates are
/// exhausted, and the card falls back to the stills the tools captured. A
/// screen that cannot be reached is not an error worth a red banner in the
/// middle of a conversation.
class BrowserLiveStreamView extends StatefulWidget {
  /// Addresses to try, best first.
  final List<String> candidates;

  /// Auth for the endpoint, when it sits behind the same gate as the gateway.
  final Map<String, String> headers;

  /// How many failed attempts one address gets before the next is tried.
  final int attemptsPerCandidate;

  /// Called when no candidate produced a frame. The card stops asking for a
  /// live view for the rest of the turn.
  final VoidCallback? onUnavailable;

  /// Called the first time a frame arrives, so the card can label itself.
  final VoidCallback? onLive;

  /// Shown until the first frame lands — normally the last captured still, so
  /// the viewport never goes blank while the stream connects.
  final Widget? placeholder;

  final BrowserStreamClient? client;

  const BrowserLiveStreamView({
    required this.candidates,
    this.headers = const {},
    this.attemptsPerCandidate = 2,
    this.onUnavailable,
    this.onLive,
    this.placeholder,
    this.client,
    super.key,
  });

  @override
  State<BrowserLiveStreamView> createState() => _BrowserLiveStreamViewState();
}

class _BrowserLiveStreamViewState extends State<BrowserLiveStreamView> {
  late final BrowserStreamClient _client;
  bool _ownsClient = false;
  StreamSubscription<Uint8List>? _subscription;

  Uint8List? _frame;
  int _candidate = 0;
  BrowserStreamStatus _status = BrowserStreamStatus.connecting;

  @override
  void initState() {
    super.initState();
    final provided = widget.client;
    _client = provided ?? BrowserStreamClient();
    _ownsClient = provided == null;
    _connect();
  }

  @override
  void didUpdateWidget(covariant BrowserLiveStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different address list is a different stream; the frames in flight
    // belong to the old one.
    if (!_sameCandidates(oldWidget.candidates, widget.candidates)) {
      _candidate = 0;
      _frame = null;
      _connect();
    }
  }

  static bool _sameCandidates(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _connect() {
    _subscription?.cancel();
    _subscription = null;
    if (_candidate >= widget.candidates.length) {
      widget.onUnavailable?.call();
      return;
    }
    final url = widget.candidates[_candidate];
    var live = false;
    _subscription =
        _client
            .frames(
              url,
              headers: widget.headers,
              maxFailedAttempts: widget.attemptsPerCandidate,
              onStatus: (status) {
                if (!mounted) return;
                if (status == BrowserStreamStatus.live && !live) {
                  live = true;
                  widget.onLive?.call();
                }
                setState(() => _status = status);
              },
            )
            .listen(
              (frame) {
                if (!mounted) return;
                setState(() => _frame = frame);
              },
              // The stream ends only when this address is spent: blocked
              // outright, or out of attempts. Either way, try the next one.
              onDone: _advance,
              onError: (Object _) => _advance(),
              cancelOnError: true,
            );
  }

  void _advance() {
    if (!mounted) return;
    _candidate++;
    _connect();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    if (_ownsClient) _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    if (frame == null) {
      return widget.placeholder ?? _connectingPlaceholder(context);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // The card gives this view a box already cut to the browser's own
        // 16:9 shape, so the frame FILLS it: a frame at that ratio lands
        // edge to edge with nothing cropped, and one slightly off it is
        // trimmed evenly around the centre rather than painted inside black
        // bars. `contain` was what left a dead strip down one side whenever a
        // frame came back off-ratio.
        Image.memory(
          frame,
          fit: BoxFit.cover,
          alignment: Alignment.center,
          // Without this the viewport flashes empty between every frame.
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              widget.placeholder ?? const SizedBox.shrink(),
        ),
        if (_status == BrowserStreamStatus.reconnecting)
          const Positioned(
            right: 6,
            top: 6,
            child: _ReconnectingDot(),
          ),
      ],
    );
  }

  Widget _connectingPlaceholder(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Center(
      child: SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          valueColor: AlwaysStoppedAnimation<Color>(colors.textSecondary),
        ),
      ),
    );
  }
}

/// The stream dropped and is being picked back up. Small on purpose: the last
/// frame is still on screen and still worth looking at.
class _ReconnectingDot extends StatelessWidget {
  const _ReconnectingDot();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: colors.warning,
        shape: BoxShape.circle,
      ),
    );
  }
}
