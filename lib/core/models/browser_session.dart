/// Live projection of what the agent's browser is doing, so a run can be
/// watched from inside the chat instead of a separate viewer tab.
///
/// Everything modelled here is derived from tool events the gateway already
/// emits (`tool.start` / `tool.complete`). The client never drives the browser
/// itself, so this file only describes what a tool payload can honestly carry:
/// the action, the page it happened on, the frame the tool handed back, and —
/// when the page is stuck on something only a human can supply — the field the
/// agent needs a value for.
library;

/// What the agent asked the browser to do.
///
/// Stacks disagree on tool names (`browser_navigate`, `puppeteer_navigate`,
/// `go_to_url`, `navigate_page`), so the action is classified once at parse
/// time and the rest of the app reasons about the verb, never the name.
enum BrowserAction {
  navigate,
  click,
  type,
  submit,
  scroll,
  screenshot,
  snapshot,
  extract,
  waitFor,
  back,
  forward,
  select,
  press,
  upload,
  evaluate,
  tab,
  close,
  other,
}

/// Lifecycle of one browser step inside the current turn.
enum BrowserStepStatus { running, done, failed }

/// How a captured frame can be rendered.
enum BrowserFrameKind {
  /// Inline bytes the tool handed back (`data:image/png;base64,…`, an MCP
  /// image content block, or a bare base64 payload). Rendered from memory.
  dataUri,

  /// A URL the viewer serves. Only private/Tailscale/HTTPS destinations are
  /// accepted; see `browser_activity.dart`.
  httpUrl,
}

/// Upper bounds. A browser run can emit a frame per step for hundreds of
/// steps; none of it is worth an OOM. Frames live in memory only and are
/// dropped when the next turn starts.
abstract final class BrowserSessionLimits {
  /// Longest accepted `source` for a single inline frame. A full-page PNG of a
  /// desktop-sized viewport clears 1 MB on an ordinary page before base64
  /// inflates it by a third, so the cap has to sit well above that: a frame
  /// over it is dropped in silence, and the card goes on saying it is waiting
  /// for a first frame that already arrived.
  static const int frameSourceCharacters = 4 * 1024 * 1024;

  /// Total inline frame bytes retained across the whole session.
  static const int retainedFrameCharacters = 8 * 1024 * 1024;

  /// Longest JSON text decoded back out of a tool payload. A tool that
  /// serialised its whole result — screenshot included — into one string is
  /// the common case, so this has to clear [frameSourceCharacters] with room
  /// for the envelope around it. Anything longer is left as the string it
  /// arrived as rather than parsed.
  static const int payloadCharacters = 8 * 1024 * 1024;

  /// How many frames stay scrubbable behind the newest one.
  static const int retainedFrames = 4;

  /// How many steps stay in the timeline; older ones collapse into a count.
  static const int retainedSteps = 40;

  static const int urlCharacters = 2048;
  static const int labelCharacters = 160;
  static const int detailCharacters = 400;
}

String? _bounded(Object? value, int limit) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= limit ? trimmed : trimmed.substring(0, limit);
}

/// One rendered picture of the page.
final class BrowserFrame {
  final BrowserFrameKind kind;

  /// A `data:` URI, or an absolute http(s) URL, depending on [kind].
  final String source;

  /// The step this frame arrived with, so the timeline and the viewport can
  /// stay in sync when the user scrubs back.
  final String? stepId;

  /// Page address at capture time, for the frame's caption.
  final String? url;

  final DateTime capturedAt;

  BrowserFrame({
    required this.kind,
    required this.source,
    required this.capturedAt,
    this.stepId,
    this.url,
  });

  /// Rough retained cost of this frame. A URL frame costs nothing — the bytes
  /// live in the image cache, which evicts on its own.
  int get retainedCharacters =>
      kind == BrowserFrameKind.dataUri ? source.length : 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BrowserFrame &&
          kind == other.kind &&
          source == other.source &&
          stepId == other.stepId;

  @override
  int get hashCode => Object.hash(kind, source, stepId);
}

/// One action the browser took, as shown in the timeline.
final class BrowserStep {
  /// Tool call id when the payload carried one, otherwise a synthetic id. It
  /// is what pairs a `tool.complete` with the `tool.start` that opened it.
  final String id;

  final BrowserAction action;

  /// What the action acted ON, as a bare noun: a host, a field name, a link
  /// text, a selector. The phrasing around it ("Opened …", "Typed into …")
  /// belongs to the widget, which has the locale; a service does not.
  final String? target;

  /// Page the step acted on, when the payload named one.
  final String? url;

  final BrowserStepStatus status;

  /// Failure text or a one-line result summary.
  final String? detail;

  const BrowserStep({
    required this.id,
    required this.action,
    required this.status,
    this.target,
    this.url,
    this.detail,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BrowserStep &&
          id == other.id &&
          action == other.action &&
          target == other.target &&
          url == other.url &&
          status == other.status &&
          detail == other.detail;

  @override
  int get hashCode => Object.hash(id, action, target, url, status, detail);
}

/// A value the page needs and only the user can supply: a login, a one-time
/// code, a captcha answer, a field the agent deliberately left blank.
///
/// The request is a prompt, never a store: whatever the user types is handed
/// straight to the agent and is not retained here.
final class BrowserInputRequest {
  /// Step that raised the request.
  final String stepId;

  /// Field label as the page or the tool named it ("Email", "Verification
  /// code"). Null when the tool only said that input was needed.
  final String? field;

  /// Longer question, when the tool supplied one.
  final String? question;

  /// Page the field lives on.
  final String? url;

  /// True for passwords, PINs, OTPs and card fields: the composer obscures
  /// the text and the value never reaches a log or the step timeline.
  final bool secret;

  const BrowserInputRequest({
    required this.stepId,
    this.field,
    this.question,
    this.url,
    this.secret = false,
  });

  factory BrowserInputRequest.build({
    required String stepId,
    Object? field,
    Object? question,
    Object? url,
    required bool secret,
  }) => BrowserInputRequest(
    stepId: stepId,
    field: _bounded(field, BrowserSessionLimits.labelCharacters),
    question: _bounded(question, BrowserSessionLimits.detailCharacters),
    url: _bounded(url, BrowserSessionLimits.urlCharacters),
    secret: secret,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BrowserInputRequest &&
          stepId == other.stepId &&
          field == other.field &&
          question == other.question &&
          url == other.url &&
          secret == other.secret;

  @override
  int get hashCode => Object.hash(stepId, field, question, url, secret);
}

/// Everything the chat needs to draw the browser surface for one turn.
final class BrowserSessionState {
  /// Newest step last.
  final List<BrowserStep> steps;

  /// Steps dropped off the front of [steps] to respect the retention cap.
  final int droppedSteps;

  /// Oldest frame first; the last entry is what the viewport shows.
  final List<BrowserFrame> frames;

  /// Current page address, as last reported by any step.
  final String? url;

  /// Current page title, when a tool reported one.
  final String? title;

  /// Outstanding ask for a value only the user can give.
  final BrowserInputRequest? inputRequest;

  const BrowserSessionState({
    this.steps = const [],
    this.droppedSteps = 0,
    this.frames = const [],
    this.url,
    this.title,
    this.inputRequest,
  });

  static const BrowserSessionState empty = BrowserSessionState();

  bool get isEmpty => steps.isEmpty && frames.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// The frame the viewport shows.
  BrowserFrame? get currentFrame => frames.isEmpty ? null : frames.last;

  /// True while a step is still open — the browser is mid-action.
  bool get isBusy =>
      steps.any((step) => step.status == BrowserStepStatus.running);

  BrowserSessionState copyWith({
    List<BrowserStep>? steps,
    int? droppedSteps,
    List<BrowserFrame>? frames,
    String? url,
    String? title,
    BrowserInputRequest? inputRequest,
    bool clearInputRequest = false,
  }) => BrowserSessionState(
    steps: steps ?? this.steps,
    droppedSteps: droppedSteps ?? this.droppedSteps,
    frames: frames ?? this.frames,
    url: url ?? this.url,
    title: title ?? this.title,
    inputRequest: clearInputRequest ? null : inputRequest ?? this.inputRequest,
  );
}
