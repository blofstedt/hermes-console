import '../models/browser_session.dart';
import '../utils/browser_activity.dart';

/// One browser tool event, normalised out of a `tool.start` / `tool.complete`
/// payload before it reaches the reducer.
///
/// The gateway does not label browser tools as such; [BrowserToolEvent.tryParse]
/// is the filter that decides a payload is one, so the reducer itself never
/// has to guess.
final class BrowserToolEvent {
  /// Tool call id, or a synthetic fallback when the payload carried none.
  final String callId;

  final BrowserAction action;

  /// Tool arguments as sent.
  final Object? input;

  /// Whatever the tool returned. Null while the step is still open.
  final Object? result;

  /// True for `tool.start`, false for `tool.complete`.
  final bool running;

  final bool failed;

  final DateTime at;

  const BrowserToolEvent({
    required this.callId,
    required this.action,
    required this.running,
    required this.at,
    this.input,
    this.result,
    this.failed = false,
  });

  /// Reads a gateway tool payload, returning null when it is not a browser
  /// tool. Accepts both the Desktop shape (`name`/`input`/`result`) and the
  /// REST run shape (`tool`/`arguments`/`output`).
  static BrowserToolEvent? tryParse(
    Map<String, dynamic> payload, {
    required bool running,
    DateTime? at,
    int sequence = 0,
  }) {
    final name = payload['name'] ?? payload['tool'] ?? payload['tool_name'];
    if (!isBrowserTool(name)) return null;

    final callId =
        _text(
          payload['tool_call_id'] ??
              payload['tool_id'] ??
              payload['call_id'] ??
              payload['id'],
        ) ??
        // No id means start and complete cannot be paired by identity. Falling
        // back to the tool name keeps the two halves of one step together for
        // the common serial case, and the sequence keeps distinct calls apart.
        'browser-${normalizeBrowserToolName(name) ?? 'step'}-$sequence';

    final result = payload['result'] ?? payload['output'] ?? payload['content'];

    return BrowserToolEvent(
      callId: callId,
      action: classifyBrowserAction(name),
      input:
          payload['input'] ??
          payload['arguments'] ??
          payload['args'] ??
          payload['params'] ??
          payload['preview'],
      result: running ? null : result,
      running: running,
      failed:
          payload['error'] != null ||
          payload['error'] == true ||
          _text(payload['status'])?.toLowerCase() == 'error',
      at: at ?? DateTime.now(),
    );
  }
}

String? _text(Object? value) {
  if (value == null) return null;
  final raw = value is String ? value : value.toString();
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Folds browser tool events into the state the chat card renders.
///
/// Pure and total: an event that carries nothing new returns the state
/// unchanged (identically, so the UI can skip the rebuild), and no event can
/// make the state grow without bound.
abstract final class BrowserActivityReducer {
  static BrowserSessionState reduce(
    BrowserSessionState state,
    BrowserToolEvent event,
  ) {
    final url = browserUrlFrom(event.result) ?? browserUrlFrom(event.input);
    final title = browserTitleFrom(event.result, url: url);
    final target = _targetOf(event, url: url);
    final status = event.running
        ? BrowserStepStatus.running
        : event.failed
        ? BrowserStepStatus.failed
        : BrowserStepStatus.done;

    final steps = List<BrowserStep>.of(state.steps);
    final existing = steps.indexWhere((step) => step.id == event.callId);
    final step = BrowserStep(
      id: event.callId,
      action: event.action,
      status: status,
      target: target ?? (existing >= 0 ? steps[existing].target : null),
      url: url ?? (existing >= 0 ? steps[existing].url : null),
      detail: _detailOf(event),
    );
    if (existing >= 0) {
      // A completion never reopens a step, and a late duplicate of an event we
      // already folded in must not append a second row.
      if (steps[existing] == step) return state;
      steps[existing] = step;
    } else {
      steps.add(step);
    }

    var dropped = state.droppedSteps;
    while (steps.length > BrowserSessionLimits.retainedSteps) {
      steps.removeAt(0);
      dropped++;
    }

    final frames = _withFrame(
      state.frames,
      browserFrameFrom(
        event.result,
        capturedAt: event.at,
        stepId: event.callId,
        url: url ?? state.url,
      ),
    );

    final request = event.running
        ? null
        : browserInputRequestFrom(
            stepId: event.callId,
            action: event.action,
            input: event.input,
            result: event.result,
            url: url ?? state.url,
          );

    // An answered request is cleared by the next step the browser takes: if
    // the run moved on, whatever it was waiting for is no longer outstanding.
    final priorRequest = state.inputRequest;
    final keepPrior =
        priorRequest != null && priorRequest.stepId == event.callId;

    // Built directly rather than through copyWith: a navigation to a new page
    // must be able to CLEAR a stale title, and copyWith cannot express that.
    return BrowserSessionState(
      steps: List<BrowserStep>.unmodifiable(steps),
      droppedSteps: dropped,
      frames: frames,
      url: url ?? state.url,
      title: title ?? (url != null && url != state.url ? null : state.title),
      inputRequest: request ?? (keepPrior ? priorRequest : null),
    );
  }

  /// Drops the request the user just answered, without disturbing anything
  /// else. Called when the answer has been handed to the agent.
  static BrowserSessionState clearInputRequest(BrowserSessionState state) =>
      state.inputRequest == null
      ? state
      : state.copyWith(clearInputRequest: true);
}

/// Appends [frame] and evicts oldest-first until the retention budget holds.
List<BrowserFrame> _withFrame(List<BrowserFrame> current, BrowserFrame? frame) {
  if (frame == null) return current;
  // A tool that returns the same screenshot twice (a snapshot right after a
  // screenshot, say) should not push a real earlier frame out of the buffer.
  // Compared by picture alone: the same bytes from a different step are still
  // the same picture.
  final last = current.isEmpty ? null : current.last;
  if (last != null && last.kind == frame.kind && last.source == frame.source) {
    return current;
  }

  final frames = List<BrowserFrame>.of(current)..add(frame);
  var retained = frames.fold<int>(
    0,
    (total, item) => total + item.retainedCharacters,
  );
  while (frames.length > 1 &&
      (frames.length > BrowserSessionLimits.retainedFrames ||
          retained > BrowserSessionLimits.retainedFrameCharacters)) {
    retained -= frames.removeAt(0).retainedCharacters;
  }
  return List<BrowserFrame>.unmodifiable(frames);
}

/// The noun the step acted on. Host for a navigation, field or link text for
/// everything else — never the raw arguments blob.
String? _targetOf(BrowserToolEvent event, {String? url}) {
  if (event.action == BrowserAction.navigate && url != null) {
    final host = Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) return host;
  }
  final input = event.input;
  if (input is Map) {
    for (final key in const [
      'element',
      'label',
      'field',
      'name',
      'text',
      'selector',
      'ref',
      'query',
      'value',
      'key',
    ]) {
      final value = input[key];
      if (value is! String) continue;
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      // Never surface what was typed into a field that looks like a secret;
      // the element description is what the user needs to see anyway.
      if (key == 'text' || key == 'value') {
        if (isPlaceholderInputValue(trimmed)) continue;
        if (event.action == BrowserAction.type) continue;
      }
      return trimmed.length <= BrowserSessionLimits.labelCharacters
          ? trimmed
          : '${trimmed.substring(0, BrowserSessionLimits.labelCharacters)}…';
    }
  }
  if (url != null) return Uri.tryParse(url)?.host;
  return null;
}

/// One line of context for a finished step: the failure, or nothing.
String? _detailOf(BrowserToolEvent event) {
  if (event.running) return null;
  final result = event.result;
  if (!event.failed) return null;
  final text = result is String ? result : jsonEncodeSafe(result);
  if (text == null || text.isEmpty) return null;
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return null;
  return flat.length <= BrowserSessionLimits.detailCharacters
      ? flat
      : '${flat.substring(0, BrowserSessionLimits.detailCharacters)}…';
}
