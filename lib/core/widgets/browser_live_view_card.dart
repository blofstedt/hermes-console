import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../models/browser_session.dart';
import '../theme/app_theme.dart';
import '../services/browser_stream_client.dart';
import 'browser_live_stream_view.dart';
import 'hermes_premium_ui.dart';
import 'hermes_ui.dart';

/// The browser, inside the chat.
///
/// Draws whatever the agent's browser tools handed back — the latest frame,
/// the page it is on, the steps it took — so a run can be watched without
/// leaving the conversation for a separate viewer. When a step is parked on a
/// value only the user can give (a login, a one-time code), the same card asks
/// for it and hands the answer straight to the agent.
///
/// The card is a projection, never a driver: it has no connection to the
/// browser and cannot click anything. Everything it shows arrived as a tool
/// event.
class BrowserLiveViewCard extends StatefulWidget {
  final BrowserSessionState session;

  /// True while an answer is in flight to the agent.
  final bool busy;

  /// Hands the user's answer to the agent. Null disables the composer.
  final ValueChanged<String>? onSubmitInput;

  /// Opens [url] in the phone's own browser.
  final ValueChanged<String>? onOpenUrl;

  /// Addresses the live MJPEG view might be served at, best first. Empty
  /// disables the live view and leaves the card showing captured stills.
  final List<String> streamCandidates;

  /// Auth for the stream endpoint, when it sits behind the same gate as the
  /// rest of the instance.
  final Map<String, String> streamHeaders;

  /// Injection seam for tests; null means the view opens its own client.
  final BrowserStreamClient? streamClient;

  const BrowserLiveViewCard({
    required this.session,
    this.busy = false,
    this.onSubmitInput,
    this.onOpenUrl,
    this.streamCandidates = const [],
    this.streamHeaders = const {},
    this.streamClient,
    super.key,
  });

  @override
  State<BrowserLiveViewCard> createState() => _BrowserLiveViewCardState();
}

class _BrowserLiveViewCardState extends State<BrowserLiveViewCard> {
  final TextEditingController _input = TextEditingController();
  bool _stepsExpanded = false;

  /// Frame the user scrubbed back to. Null means "follow the live edge", so a
  /// new frame does not yank the viewport away from someone looking at an
  /// earlier one.
  int? _pinnedFrame;

  /// The live view was tried and no address answered. Kept for the life of
  /// this card — which is the life of one turn — so a deployment without the
  /// stream published does not re-dial on every rebuild. A later turn tries
  /// again, so publishing the route mid-conversation is picked up.
  bool _streamUnavailable = false;

  /// A frame has arrived from the live view: the badge can say so, and the
  /// viewport is showing the screen rather than a still.
  bool _streamLive = false;

  @override
  void didUpdateWidget(covariant BrowserLiveViewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pinned = _pinnedFrame;
    if (pinned != null && pinned >= widget.session.frames.length) {
      _pinnedFrame = null;
    }
    // A fresh request is a fresh question: never leave the previous answer
    // sitting in the field where it could be submitted against the new one.
    if (oldWidget.session.inputRequest != widget.session.inputRequest) {
      _input.clear();
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final handler = widget.onSubmitInput;
    if (handler == null || widget.busy) return;
    final value = _input.text.trim();
    if (value.isEmpty) return;
    _input.clear();
    handler(value);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    if (session.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final frames = session.frames;
    final frameIndex =
        _pinnedFrame ?? (frames.isEmpty ? -1 : frames.length - 1);
    final frame = frameIndex >= 0 && frameIndex < frames.length
        ? frames[frameIndex]
        : null;

    // The live view is worth opening only while the browser is actually doing
    // something, and only while the user is watching the newest frame: someone
    // scrubbed back to step 3 is reading history, not watching a screen.
    final candidates = _streamCandidates();
    final wantsStream =
        candidates.isNotEmpty &&
        !_streamUnavailable &&
        session.isBusy &&
        _pinnedFrame == null;

    return HermesCard(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: EdgeInsets.zero,
      glow: session.isBusy,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(colors, s, streaming: wantsStream && _streamLive),
          _BrowserViewport(
            frame: frame,
            busy: session.isBusy,
            emptyLabel: s.browserLiveWaitingFrame,
            stream: wantsStream
                ? BrowserLiveStreamView(
                    // Keyed by address so a new stream address rebuilds the
                    // view rather than reusing a connection to the old one.
                    key: ValueKey<String>(candidates.join('|')),
                    candidates: candidates,
                    headers: widget.streamHeaders,
                    client: widget.streamClient,
                    onUnavailable: () {
                      if (mounted) setState(() => _streamUnavailable = true);
                    },
                    onLive: () {
                      if (mounted && !_streamLive) {
                        setState(() => _streamLive = true);
                      }
                    },
                    placeholder: frame == null
                        ? null
                        : ClipRect(
                            child: BrowserFrameImage(
                              frame: frame,
                              fit: BoxFit.contain,
                              alignment: Alignment.topCenter,
                            ),
                          ),
                  )
                : null,
            onTap: frame == null
                ? null
                : () => showBrowserFrameViewer(
                    context: context,
                    frame: frame,
                    caption: session.url,
                  ),
          ),
          if (frames.length > 1)
            _FrameScrubber(
              count: frames.length,
              index: frameIndex,
              latestLabel: s.browserLiveFrameLatest,
              onSelect: (index) => setState(
                () => _pinnedFrame = index == frames.length - 1 ? null : index,
              ),
            ),
          if (session.inputRequest != null)
            _InputRequestBlock(
              request: session.inputRequest!,
              controller: _input,
              busy: widget.busy,
              enabled: widget.onSubmitInput != null,
              onSubmit: _submit,
            ),
          _stepsSection(colors, s),
        ],
      ),
    );
  }

  /// Where to look for the live view, best first.
  ///
  /// An address the server itself advertised in a tool result always wins: it
  /// knows where it published the feed, and the app is only guessing.
  List<String> _streamCandidates() {
    final advertised = widget.session.streamUrl;
    if (advertised == null) return widget.streamCandidates;
    return <String>[
      advertised,
      for (final candidate in widget.streamCandidates)
        if (candidate != advertised) candidate,
    ];
  }

  Widget _header(
    HermesThemeColors colors,
    Strings s, {
    required bool streaming,
  }) {
    final session = widget.session;
    final url = session.url;
    final host = url == null ? null : Uri.tryParse(url)?.host;
    final subtitle = session.title ?? host;
    final onOpenUrl = widget.onOpenUrl;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
      child: Row(
        children: [
          Icon(Icons.public, size: 16, color: colors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  subtitle == null || subtitle.isEmpty
                      ? s.browserLiveTitle
                      : subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                if (url != null)
                  Text(
                    url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          HermesBadge(
            // "Live view" is claimed only while the screen is genuinely
            // streaming: a busy tool handing back stills is live ACTIVITY,
            // not a live picture, and a turn that ended is neither.
            streaming
                ? s.browserLiveBadgeStreaming
                : session.isBusy
                ? s.browserLiveBadgeLive
                : s.browserLiveBadgeIdle,
            color: session.isBusy ? colors.success : colors.textDisabled,
            dot: session.isBusy,
          ),
          if (url != null && onOpenUrl != null)
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 16),
              color: colors.textSecondary,
              visualDensity: VisualDensity.compact,
              tooltip: s.browserLiveOpenExternally,
              onPressed: () => onOpenUrl(url),
            ),
        ],
      ),
    );
  }

  Widget _stepsSection(HermesThemeColors colors, Strings s) {
    final steps = widget.session.steps;
    if (steps.isEmpty) return const SizedBox.shrink();
    // Collapsed, the timeline is just the step in flight (or the last one) —
    // enough to follow along without turning the bubble into a log.
    final visible = _stepsExpanded ? steps : steps.sublist(steps.length - 1);
    // What collapsing WOULD hide. Computed from the collapsed shape, not the
    // current one, so the toggle does not vanish once the list is open.
    final collapsible = steps.length - 1 + widget.session.droppedSteps;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: colors.divider.withValues(alpha: 0.4)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final step in visible)
                _StepRow(key: ValueKey(step.id), step: step),
              if (collapsible > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: InkWell(
                    onTap: () =>
                        setState(() => _stepsExpanded = !_stepsExpanded),
                    child: Text(
                      _stepsExpanded
                          ? s.browserLiveStepsCollapse
                          : s.browserLiveStepsExpand(collapsible),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colors.accent,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Viewport ────────────────────────────────────────────────────────────────

class _BrowserViewport extends StatelessWidget {
  final BrowserFrame? frame;
  final bool busy;
  final String emptyLabel;
  final VoidCallback? onTap;

  /// The live view, when one is worth opening. It falls back to [frame] on its
  /// own while connecting, so the viewport never blanks.
  final Widget? stream;

  const _BrowserViewport({
    required this.frame,
    required this.busy,
    required this.emptyLabel,
    this.stream,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final current = frame;
    final live = stream;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        color: colors.background,
        constraints: const BoxConstraints(minHeight: 96, maxHeight: 320),
        child: live != null
            ? ClipRect(child: live)
            : current == null
            ? _placeholder(colors)
            : ClipRect(
                child: BrowserFrameImage(
                  frame: current,
                  fit: BoxFit.contain,
                  alignment: Alignment.topCenter,
                ),
              ),
      ),
    );
  }

  Widget _placeholder(HermesThemeColors colors) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(colors.textSecondary),
            ),
          )
        else
          Icon(Icons.image_outlined, size: 15, color: colors.textDisabled),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            emptyLabel,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ),
      ],
    ),
  );
}

/// Renders one frame, whichever way it arrived.
///
/// Inline frames decode once per source: [Image.memory] would otherwise
/// re-decode a multi-megabyte PNG on every rebuild of a streaming turn.
class BrowserFrameImage extends StatefulWidget {
  final BrowserFrame frame;
  final BoxFit fit;
  final Alignment alignment;

  const BrowserFrameImage({
    required this.frame,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    super.key,
  });

  @override
  State<BrowserFrameImage> createState() => _BrowserFrameImageState();
}

class _BrowserFrameImageState extends State<BrowserFrameImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant BrowserFrameImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame.source != widget.frame.source) _decode();
  }

  void _decode() {
    if (widget.frame.kind != BrowserFrameKind.dataUri) {
      _bytes = null;
      _failed = false;
      return;
    }
    try {
      _bytes = UriData.parse(widget.frame.source).contentAsBytes();
      _failed = false;
    } catch (_) {
      // A truncated or malformed frame is a dropped frame, never a crash: the
      // run keeps going and the viewport just shows the placeholder.
      _bytes = null;
      _failed = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    Widget broken() => Center(
      child: Icon(
        Icons.broken_image_outlined,
        size: 18,
        color: colors.textDisabled,
      ),
    );

    if (widget.frame.kind == BrowserFrameKind.dataUri) {
      final bytes = _bytes;
      if (_failed || bytes == null) return broken();
      return Image.memory(
        bytes,
        fit: widget.fit,
        alignment: widget.alignment,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => broken(),
      );
    }
    return Image.network(
      widget.frame.source,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => broken(),
    );
  }
}

/// Opens one frame full-screen, pinch-zoomable.
Future<void> showBrowserFrameViewer({
  required BuildContext context,
  required BrowserFrame frame,
  String? caption,
}) => showHermesFloatingSurface<void>(
  context: context,
  surfaceKey: const ValueKey('browser-frame-viewer'),
  maxWidth: 900,
  maxHeightFactor: 0.92,
  builder: (viewerContext) {
    final colors = Theme.of(viewerContext).hermes;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: InteractiveViewer(
            maxScale: 6,
            child: BrowserFrameImage(frame: frame, fit: BoxFit.contain),
          ),
        ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Text(
              caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.textSecondary),
            ),
          ),
      ],
    );
  },
);

// ── Scrubber ────────────────────────────────────────────────────────────────

class _FrameScrubber extends StatelessWidget {
  final int count;
  final int index;
  final String latestLabel;
  final ValueChanged<int> onSelect;

  const _FrameScrubber({
    required this.count,
    required this.index,
    required this.latestLabel,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Row(
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Semantics(
                selected: i == index,
                button: true,
                child: GestureDetector(
                  key: ValueKey<String>('browser-frame-dot-$i'),
                  onTap: () => onSelect(i),
                  child: Container(
                    width: i == index ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == index
                          ? colors.accent
                          : colors.divider.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          if (index != count - 1)
            GestureDetector(
              onTap: () => onSelect(count - 1),
              child: Text(
                latestLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: colors.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Steps ───────────────────────────────────────────────────────────────────

class _StepRow extends StatelessWidget {
  final BrowserStep step;

  const _StepRow({required this.step, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final (icon, color) = switch (step.status) {
      BrowserStepStatus.running => (Icons.more_horiz, colors.accent),
      BrowserStepStatus.done => (Icons.check, colors.success),
      BrowserStepStatus.failed => (Icons.close, colors.error),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 12, color: color),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: browserActionVerb(s, step.action),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (step.target != null)
                        TextSpan(
                          text: ' ${step.target}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (step.detail != null)
                  Text(
                    step.detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.error),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The verb shown for one action. The target noun is rendered beside it, so
/// these stay short and never interpolate untrusted page text.
String browserActionVerb(Strings s, BrowserAction action) => switch (action) {
  BrowserAction.navigate => s.browserVerbNavigate,
  BrowserAction.click => s.browserVerbClick,
  BrowserAction.type => s.browserVerbType,
  BrowserAction.submit => s.browserVerbSubmit,
  BrowserAction.scroll => s.browserVerbScroll,
  BrowserAction.screenshot => s.browserVerbScreenshot,
  BrowserAction.snapshot => s.browserVerbSnapshot,
  BrowserAction.extract => s.browserVerbExtract,
  BrowserAction.waitFor => s.browserVerbWait,
  BrowserAction.back => s.browserVerbBack,
  BrowserAction.forward => s.browserVerbForward,
  BrowserAction.select => s.browserVerbSelect,
  BrowserAction.press => s.browserVerbPress,
  BrowserAction.upload => s.browserVerbUpload,
  BrowserAction.evaluate => s.browserVerbEvaluate,
  BrowserAction.tab => s.browserVerbTab,
  BrowserAction.close => s.browserVerbClose,
  BrowserAction.other => s.browserVerbOther,
};

// ── "Hermes needs something from you" ───────────────────────────────────────

class _InputRequestBlock extends StatelessWidget {
  final BrowserInputRequest request;
  final TextEditingController controller;
  final bool busy;
  final bool enabled;
  final VoidCallback onSubmit;

  const _InputRequestBlock({
    required this.request,
    required this.controller,
    required this.busy,
    required this.enabled,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final s = Strings.of(context);
    final field = request.field;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                request.secret ? Icons.lock_outline : Icons.edit_outlined,
                size: 14,
                color: colors.accent,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  s.browserInputTitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (request.question != null) ...[
            const SizedBox(height: 5),
            Text(
              request.question!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: 9),
          TextField(
            controller: controller,
            enabled: enabled && !busy,
            obscureText: request.secret,
            autocorrect: !request.secret,
            enableSuggestions: !request.secret,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSubmit(),
            style: TextStyle(fontSize: 13, color: colors.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: colors.surface,
              hintText: field == null || field.isEmpty
                  ? s.browserInputHint
                  : field,
              hintStyle: TextStyle(fontSize: 13, color: colors.textDisabled),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 11,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.accent),
              ),
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              if (request.secret)
                Expanded(
                  child: Text(
                    s.browserInputSecretNote,
                    style: TextStyle(fontSize: 10, color: colors.textDisabled),
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: 8),
              _SendButton(
                label: s.browserInputSend,
                busy: busy,
                onTap: enabled && !busy ? onSubmit : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact accent button for the input row. The shared primary button is
/// full-width by design; this row needs it to sit next to the secret note.
class _SendButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback? onTap;

  const _SendButton({required this.label, required this.busy, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final radius = Theme.of(
      context,
    ).hermesComponents.profile.shape.buttonRadius;
    final enabled = onTap != null;
    return PressableScale(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: enabled ? colors.accent : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  valueColor: AlwaysStoppedAnimation<Color>(colors.onAccent),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: enabled ? colors.onAccent : colors.textDisabled,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
