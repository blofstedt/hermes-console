/// Recognises browser tool traffic inside the ordinary tool event stream and
/// pulls out the few things the chat surface needs: the verb, the page, the
/// frame, and any field the run is stuck waiting on.
///
/// There is no single browser tool contract. Playwright, Puppeteer, the Chrome
/// DevTools MCP, browser-use and Steel all name their tools differently and
/// shape their results differently, and an MCP bridge prefixes whatever it
/// wraps (`mcp__playwright__browser_navigate`). So nothing here matches an
/// exact payload: every helper is a bounded, fail-closed search over whatever
/// arrived. A payload that does not look like a browser is simply not one, and
/// the chat renders as it always has.
library;

import 'dart:convert';

import '../models/browser_session.dart';
import 'transport_privacy.dart';

// ── Tool identity ───────────────────────────────────────────────────────────

/// Strips MCP/namespace decoration and returns the bare verb, lowercased.
///
/// `mcp__playwright__browser_navigate` → `browser_navigate`
/// `playwright:browser.click` → `click`
String? normalizeBrowserToolName(Object? raw) {
  if (raw is! String) return null;
  var name = raw.trim().toLowerCase();
  if (name.isEmpty) return null;
  for (final separator in const ['__', '::', ':', '/', '.']) {
    final index = name.lastIndexOf(separator);
    if (index >= 0 && index + separator.length < name.length) {
      name = name.substring(index + separator.length);
    }
  }
  return name.isEmpty ? null : name;
}

/// Namespaces that make even an ambiguous verb (`click`, `fill`) unmistakably
/// a browser call. Matched against the FULL name, decoration included.
final RegExp _browserNamespaceRe = RegExp(
  r'browser|playwright|puppeteer|devtools|webdriver|selenium|stagehand|'
  r'browserbase|steel[_-]?browser|chromium|chrome',
);

/// Verbs specific enough to stand on their own, with no namespace to lean on.
/// Deliberately excludes bare `screenshot`/`click`/`fill`: those belong to
/// desktop and form tools just as often as to a browser.
const Set<String> _standaloneBrowserTools = {
  'go_to_url',
  'goto_url',
  'open_url',
  'navigate_page',
  'navigate_to_url',
  'input_text',
  'click_element',
  'click_element_by_index',
  'extract_content',
  'extract_page_content',
  'scroll_down',
  'scroll_up',
  'switch_tab',
  'open_tab',
  'close_tab',
  'go_back',
  'go_forward',
  'get_page_content',
  'read_page',
  'web_navigate',
};

/// True when [raw] names a tool that drives a web browser.
bool isBrowserTool(Object? raw) {
  if (raw is! String) return false;
  final full = raw.trim().toLowerCase();
  if (full.isEmpty) return false;
  final name = normalizeBrowserToolName(full);
  if (name == null) return false;
  if (_standaloneBrowserTools.contains(name)) return true;

  final namespaced = _browserNamespaceRe.hasMatch(full);
  if (!namespaced) return false;
  // Inside a browser namespace the verb no longer has to be on any list —
  // a stack we have never seen still gets its steps drawn.
  return true;
}

/// Argument that carries the verb when the tool name does not.
///
/// A stack that exposes ONE `browser` tool and switches on an `action` field
/// is as common as one tool per verb, and its steps would otherwise all read
/// as the generic "acted on".
const Set<String> _actionArgumentKeys = {
  'action',
  'method',
  'command',
  'operation',
  'verb',
  'tool_action',
  'browser_action',
};

/// Maps a tool call onto the verb the timeline shows.
///
/// [input] is consulted only when the name alone is inconclusive, and only at
/// the top level of the arguments: an `action` buried inside a page snapshot
/// describes the page, not the call.
BrowserAction classifyBrowserAction(Object? raw, {Object? input}) {
  final byName = _classifyVerb(normalizeBrowserToolName(raw));
  if (byName != BrowserAction.other) return byName;
  if (input is! Map) return BrowserAction.other;
  for (final key in _actionArgumentKeys) {
    final value = input[key];
    if (value is! String) continue;
    final verb = _classifyVerb(normalizeBrowserToolName(value));
    if (verb != BrowserAction.other) return verb;
  }
  return BrowserAction.other;
}

BrowserAction _classifyVerb(String? name) {
  if (name == null) return BrowserAction.other;
  bool has(String token) => name.contains(token);

  // Order matters: the more specific token wins. `navigate_back` must not be
  // read as a plain navigation, and `wait_for` must not be read as `for`.
  if (has('back')) return BrowserAction.back;
  if (has('forward')) return BrowserAction.forward;
  if (has('wait')) return BrowserAction.waitFor;
  if (has('snapshot')) return BrowserAction.snapshot;
  if (has('screenshot') || has('capture')) return BrowserAction.screenshot;
  if (has('navigate') || has('goto') || has('go_to') || has('open_url')) {
    return BrowserAction.navigate;
  }
  if (has('submit')) return BrowserAction.submit;
  if (has('type') || has('input_text') || has('fill')) {
    return BrowserAction.type;
  }
  if (has('click') || has('tap') || has('hover')) return BrowserAction.click;
  if (has('select')) return BrowserAction.select;
  if (has('press') || has('key')) return BrowserAction.press;
  if (has('scroll')) return BrowserAction.scroll;
  if (has('upload') || has('file')) return BrowserAction.upload;
  if (has('extract') || has('content') || has('read') || has('text')) {
    return BrowserAction.extract;
  }
  if (has('evaluate') || has('script')) return BrowserAction.evaluate;
  if (has('tab') || has('page')) return BrowserAction.tab;
  if (has('close')) return BrowserAction.close;
  return BrowserAction.other;
}

// ── Bounded search over an arbitrary payload ────────────────────────────────

/// Node budget for one walk. Tool results can nest an entire accessibility
/// tree; the surface only needs a handful of scalars off the top of it. The
/// budget is generous enough that a screenshot parked after such a tree is
/// still reached — walking already-parsed structure is cheap.
const int _maxVisitedNodes = 1200;
const int _maxDepth = 8;

/// Text that could be a JSON document. Only an object or an array is worth
/// decoding: a quoted word or a number carries nothing the surface reads.
final RegExp _jsonishRe = RegExp(r'^[\{\[]');

/// Re-types a tool payload that arrived encoded as text.
///
/// The same gateway that sends `result` as a map on one turn sends it as the
/// JSON *text* of that map on the next, and an MCP bridge routinely nests one
/// encoding inside the other (`content: [{type: text, text: "{\"url\": …}"}]`).
/// Every search in this file is a plain walk over structure, so a payload that
/// never got decoded looks empty: no page, no step target, and — the symptom
/// that gives this away — no frame, with the screenshot sitting right there in
/// the string.
///
/// Decoding happens ONCE, here at the edge, so a multi-megabyte screenshot is
/// never parsed twice for the same event. Anything that is not JSON is
/// returned untouched: a prose result stays prose, which is what the
/// input-request matcher reads.
Object? normalizeBrowserPayload(Object? payload) {
  var budget = _maxVisitedNodes;

  Object? walk(Object? node, int depth) {
    if (depth > _maxDepth || budget-- <= 0) return node;
    if (node is String) {
      final trimmed = node.trim();
      if (trimmed.length < 2 ||
          trimmed.length > BrowserSessionLimits.payloadCharacters ||
          !_jsonishRe.hasMatch(trimmed)) {
        return node;
      }
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map || decoded is List) return walk(decoded, depth + 1);
      } catch (_) {
        // Not JSON after all — prose that happens to open with a brace. It
        // stays exactly as it arrived.
      }
      return node;
    }
    if (node is Map) {
      final decoded = <String, Object?>{};
      for (final entry in node.entries) {
        final key = entry.key;
        if (key is String) decoded[key] = walk(entry.value, depth + 1);
      }
      return decoded;
    }
    if (node is List) {
      return <Object?>[for (final value in node) walk(value, depth + 1)];
    }
    return node;
  }

  return walk(payload, 0);
}

/// Decodes a payload that is still a bare JSON string, so every entry point
/// below works on whatever the caller happens to have.
///
/// A payload already normalised by [normalizeBrowserPayload] is a structure by
/// then, so this costs one type test and never decodes twice.
Object? _normalizedRoot(Object? payload) =>
    payload is String ? normalizeBrowserPayload(payload) : payload;

/// Depth-first search for the first non-empty string stored under any of
/// [keys]. Fails closed: an exhausted budget returns null rather than a guess.
String? _findString(Object? root, Set<String> keys, {int limit = 2048}) {
  var visited = 0;

  String? walk(Object? node, int depth) {
    if (node == null || depth > _maxDepth || visited++ > _maxVisitedNodes) {
      return null;
    }
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key;
        if (key is! String) continue;
        if (!keys.contains(key.toLowerCase())) continue;
        final value = entry.value;
        if (value is String && value.trim().isNotEmpty) {
          final trimmed = value.trim();
          return trimmed.length <= limit
              ? trimmed
              : trimmed.substring(0, limit);
        }
      }
      for (final value in node.values) {
        final found = walk(value, depth + 1);
        if (found != null) return found;
      }
      return null;
    }
    if (node is List) {
      for (final value in node) {
        final found = walk(value, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  return walk(root, 0);
}

/// Same walk, but for a boolean flag that may arrive as `true`/`"true"`/`1`.
bool _findFlag(Object? root, Set<String> keys) {
  var visited = 0;

  bool walk(Object? node, int depth) {
    if (node == null || depth > _maxDepth || visited++ > _maxVisitedNodes) {
      return false;
    }
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key;
        if (key is! String || !keys.contains(key.toLowerCase())) continue;
        final value = entry.value;
        if (value == true) return true;
        if (value is num && value != 0) return true;
        if (value is String && value.trim().toLowerCase() == 'true') {
          return true;
        }
      }
      for (final value in node.values) {
        if (walk(value, depth + 1)) return true;
      }
      return false;
    }
    if (node is List) {
      for (final value in node) {
        if (walk(value, depth + 1)) return true;
      }
    }
    return false;
  }

  return walk(root, 0);
}

const Set<String> _urlKeys = {
  'url',
  'current_url',
  'currenturl',
  'page_url',
  'pageurl',
  'href',
  'link',
  'target_url',
  'final_url',
  'location',
};

// Deliberately narrow: `name` appears in almost every tool result and would
// turn an unrelated field into the page title.
const Set<String> _titleKeys = {'title', 'page_title', 'pagetitle'};

/// Page address named anywhere in [payload], normalised and length-capped.
///
/// Only absolute http(s) URLs count. A selector or a bare word under a `url`
/// key is not an address and is dropped rather than shown.
String? browserUrlFrom(Object? payload) {
  final raw = _findString(
    _normalizedRoot(payload),
    _urlKeys,
    limit: BrowserSessionLimits.urlCharacters,
  );
  if (raw == null) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return raw;
}

/// Page title named anywhere in [payload]. A title that is just the URL again
/// carries nothing, so it is dropped.
String? browserTitleFrom(Object? payload, {String? url}) {
  final raw = _findString(
    _normalizedRoot(payload),
    _titleKeys,
    limit: BrowserSessionLimits.labelCharacters,
  );
  if (raw == null) return null;
  if (url != null && raw == url) return null;
  if (raw.startsWith('http://') || raw.startsWith('https://')) return null;
  return raw;
}

/// Keys a tool uses to hand back a LIVE view of the browser rather than a
/// still. A server that publishes an MJPEG feed of the session can say so in
/// its result, and that beats anything the app could guess.
const Set<String> _streamKeys = {
  'stream_url',
  'streamurl',
  'live_url',
  'liveurl',
  'live_view_url',
  'liveviewurl',
  'mjpeg_url',
  'mjpegurl',
  'preview_url',
  'view_url',
  'stream',
};

/// Live-stream address named anywhere in [payload].
///
/// Same shape rule as [browserUrlFrom] — an absolute http(s) address — because
/// a stream that is not one cannot be opened. Whether it is safe to OPEN is
/// decided at connect time, not here.
String? browserStreamUrlFrom(Object? payload) {
  final raw = _findString(
    _normalizedRoot(payload),
    _streamKeys,
    limit: BrowserSessionLimits.urlCharacters,
  );
  if (raw == null) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return raw;
}

// ── Frames ──────────────────────────────────────────────────────────────────

const Set<String> _frameKeys = {
  'screenshot',
  'screenshot_url',
  'screenshoturl',
  'screenshot_base64',
  'screenshotbase64',
  'screenshot_data',
  'screenshotdata',
  'image',
  'image_url',
  'imageurl',
  'image_base64',
  'imagebase64',
  'image_b64',
  'image_data',
  'imagedata',
  'b64_json',
  'data_uri',
  'datauri',
  'data_url',
  'dataurl',
  'frame',
  'thumbnail',
  'png',
  'jpeg',
  'jpg',
  'base64',
  'data',
};

/// A `data:` image URI pasted into prose. A tool that answers in text and puts
/// its screenshot in the middle of the sentence is handing back a frame just
/// as much as one with a schema for it.
final RegExp _embeddedDataUriRe = RegExp(
  r'data:image/[a-z0-9.+-]{1,20};base64,[A-Za-z0-9+/]+={0,2}',
  caseSensitive: false,
);

/// Floor for a data URI lifted out of surrounding text. Extracted page content
/// carries inline favicons and tracking pixels, and a 1×1 GIF must never take
/// the viewport away from a real screenshot. A picture of a page clears this
/// by orders of magnitude.
const int _minEmbeddedFrameCharacters = 512;

/// Base64 magic prefixes, so a bare payload can be typed without decoding it.
const Map<String, String> _base64Signatures = {
  'iVBORw0KGgo': 'image/png',
  '/9j/': 'image/jpeg',
  'R0lGOD': 'image/gif',
  'UklGR': 'image/webp',
};

final RegExp _base64CharsetRe = RegExp(r'^[A-Za-z0-9+/=\s]+$');
final RegExp _imageExtensionRe = RegExp(
  r'\.(?:png|jpe?g|webp|gif)(?:$|[?#])',
  caseSensitive: false,
);

/// True when an http(s) image URL may be loaded: HTTPS anywhere, or cleartext
/// only inside a network the user controls. Same rule the gateway clients use.
bool _frameUrlAllowed(String url) =>
    TransportPrivacy.classify(url) != TransportPrivacyClass.publicCleartext;

/// Turns one candidate value into a frame, or null when it is not an image.
BrowserFrame? _frameFromValue(
  Object? value, {
  required DateTime capturedAt,
  String? stepId,
  String? url,
  String? mimeHint,
}) {
  if (value is! String) return null;
  final raw = value.trim();
  if (raw.isEmpty) return null;

  if (raw.startsWith('data:image/')) {
    if (raw.length > BrowserSessionLimits.frameSourceCharacters) return null;
    return BrowserFrame(
      kind: BrowserFrameKind.dataUri,
      source: raw,
      capturedAt: capturedAt,
      stepId: stepId,
      url: url,
    );
  }

  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    // A page URL under `url` is not a frame; only an image endpoint is.
    if (!_imageExtensionRe.hasMatch(raw) &&
        !raw.toLowerCase().contains('screenshot') &&
        !raw.toLowerCase().contains('/image')) {
      return null;
    }
    if (raw.length > BrowserSessionLimits.urlCharacters) return null;
    if (!_frameUrlAllowed(raw)) return null;
    return BrowserFrame(
      kind: BrowserFrameKind.httpUrl,
      source: raw,
      capturedAt: capturedAt,
      stepId: stepId,
      url: url,
    );
  }

  // Bare base64. Typed by signature so a long opaque string that happens to
  // sit under `data` is never rendered as a broken image.
  if (raw.length < 64) return null;
  if (raw.length > BrowserSessionLimits.frameSourceCharacters) return null;
  final mime = _base64Signatures.entries
      .where((entry) => raw.startsWith(entry.key))
      .map((entry) => entry.value)
      .firstOrNull;
  final resolved = mime ?? (raw.startsWith('data:') ? null : mimeHint);
  if (resolved == null) return null;
  if (!_base64CharsetRe.hasMatch(raw)) return null;
  // Only accept what actually decodes — a truncated stream would otherwise
  // reach the image widget and throw during paint.
  try {
    base64Decode(raw.replaceAll(RegExp(r'\s'), ''));
  } catch (_) {
    return null;
  }
  return BrowserFrame(
    kind: BrowserFrameKind.dataUri,
    source: 'data:$resolved;base64,${raw.replaceAll(RegExp(r'\s'), '')}',
    capturedAt: capturedAt,
    stepId: stepId,
    url: url,
  );
}

/// Pulls a frame out of free text: the whole string as a `data:` URI, or one
/// embedded in a sentence around it.
///
/// Only reached for text the payload already pointed at as a picture — the
/// result itself, or a value under a screenshot-ish key. Scanning every string
/// in a payload would turn a favicon inside a page's HTML into "the screen".
BrowserFrame? _frameFromText(
  String text, {
  required DateTime capturedAt,
  String? stepId,
  String? url,
  String? mimeHint,
}) {
  final direct = _frameFromValue(
    text,
    capturedAt: capturedAt,
    stepId: stepId,
    url: url,
    mimeHint: mimeHint,
  );
  if (direct != null) return direct;
  final embedded = _embeddedDataUriRe.firstMatch(text)?.group(0);
  if (embedded == null || embedded.length < _minEmbeddedFrameCharacters) {
    return null;
  }
  return _frameFromValue(
    embedded,
    capturedAt: capturedAt,
    stepId: stepId,
    url: url,
  );
}

/// Finds the newest renderable frame in [payload].
///
/// Handles the shapes seen in the wild: a `data:` URI, an MCP image content
/// block (`{type: image, data, mimeType}`), a bare base64 blob under a
/// screenshot-ish key, and a result that is itself nothing but the picture.
BrowserFrame? browserFrameFrom(
  Object? payload, {
  required DateTime capturedAt,
  String? stepId,
  String? url,
}) {
  var visited = 0;

  BrowserFrame? walk(Object? node, int depth) {
    if (node == null || depth > _maxDepth || visited++ > _maxVisitedNodes) {
      return null;
    }
    if (node is Map) {
      // MCP image content block: the mime type sits beside the payload.
      final type = node['type'];
      if (type is String && type.trim().toLowerCase() == 'image') {
        final mime = node['mimeType'] ?? node['mime_type'] ?? node['mediaType'];
        final frame = _frameFromValue(
          node['data'] ?? node['image'] ?? node['source'],
          capturedAt: capturedAt,
          stepId: stepId,
          url: url,
          mimeHint: mime is String && mime.trim().startsWith('image/')
              ? mime.trim()
              : 'image/png',
        );
        if (frame != null) return frame;
      }
      for (final entry in node.entries) {
        final key = entry.key;
        if (key is! String) continue;
        if (!_frameKeys.contains(key.toLowerCase())) continue;
        final value = entry.value;
        final frame = value is String
            ? _frameFromText(
                value,
                capturedAt: capturedAt,
                stepId: stepId,
                url: url,
                // A value parked under an image-ish key is allowed to be
                // untyped base64; one under the generic `data` key is not.
                mimeHint: key.toLowerCase() == 'data' ? null : 'image/png',
              )
            : null;
        if (frame != null) return frame;
      }
      for (final value in node.values) {
        final frame = walk(value, depth + 1);
        if (frame != null) return frame;
      }
      return null;
    }
    if (node is List) {
      // Newest content block wins when a tool returns several.
      for (final value in node.reversed) {
        final frame = walk(value, depth + 1);
        if (frame != null) return frame;
      }
    }
    return null;
  }

  final root = _normalizedRoot(payload);
  // A result that is nothing but the picture: the string never had a key to
  // be found under.
  if (root is String) {
    return _frameFromText(
      root,
      capturedAt: capturedAt,
      stepId: stepId,
      url: url,
    );
  }
  return walk(root, 0);
}

// ── "The page needs something from you" ─────────────────────────────────────

const Set<String> _inputFlagKeys = {
  'needs_input',
  'needsinput',
  'input_required',
  'inputrequired',
  'requires_input',
  'requires_user_input',
  'awaiting_input',
  'awaiting_user_input',
  'needs_user',
  'user_input_required',
};

const Set<String> _fieldKeys = {
  'field',
  'field_name',
  'fieldname',
  'label',
  'placeholder',
  'input_name',
  'element',
};

const Set<String> _questionKeys = {
  'question',
  'prompt',
  'message',
  'reason',
  'ask',
  'detail',
};

/// Result text that means the run is parked on a human.
final RegExp _inputNeededRe = RegExp(
  r'requires?\s+(?:user\s+)?input|needs?\s+(?:user\s+)?input|'
  r'waiting\s+for\s+(?:the\s+)?user|user\s+input\s+(?:is\s+)?(?:required|needed)|'
  r'login\s+required|sign\s*[- ]?in\s+required|authentication\s+required|'
  r'enter\s+your\s+|please\s+enter\s+|verification\s+code|one[- ]time\s+code|'
  r'captcha|two[- ]factor|2fa|credentials?\s+(?:are\s+)?(?:required|needed)',
  caseSensitive: false,
);

/// Field names whose value must never be echoed or logged.
final RegExp _secretFieldRe = RegExp(
  r'password|passcode|\bpin\b|secret|token|cvv|cvc|otp|one[- ]?time|'
  r'2fa|two[- ]factor|verification\s*code|security\s*code|card\s*number',
  caseSensitive: false,
);

/// A `type`/`fill` argument the agent left as a placeholder rather than a
/// value — `<your email>`, `{{code}}`, `TODO`. That is the agent telling us it
/// does not know what to put there.
final RegExp _placeholderValueRe = RegExp(
  r'^\s*(?:<[^>]{1,80}>|\{\{[^}]{1,80}\}\}|\$\{[^}]{1,80}\}|todo|tbd|xxx+|'
  r'\.\.\.|your[_\s-]\w+)\s*$',
  caseSensitive: false,
);

/// True when [value] is a stand-in rather than something to type.
bool isPlaceholderInputValue(Object? value) =>
    value is String && _placeholderValueRe.hasMatch(value);

/// Decides whether this step is asking the user for a value, and for what.
///
/// [input] is the tool's arguments, [result] whatever it returned. Returns
/// null when nothing suggests a human is needed — the common case.
BrowserInputRequest? browserInputRequestFrom({
  required String stepId,
  required BrowserAction action,
  Object? input,
  Object? result,
  String? url,
}) {
  // A tool that encoded its result as JSON text is asking for a value just as
  // plainly as one that sent a structure; decode before deciding.
  final decodedInput = _normalizedRoot(input);
  final decodedResult = _normalizedRoot(result);
  final flagged =
      _findFlag(decodedResult, _inputFlagKeys) ||
      _findFlag(decodedInput, _inputFlagKeys);

  final resultText = decodedResult is String
      ? decodedResult
      : jsonEncodeSafe(decodedResult);
  final textual = resultText != null && _inputNeededRe.hasMatch(resultText);

  // A type/fill whose value is a placeholder is a request in its own right:
  // the agent reached the field and had nothing to put in it.
  final placeholderTyping =
      (action == BrowserAction.type || action == BrowserAction.select) &&
      isPlaceholderInputValue(
        _findString(decodedInput, const {'text', 'value', 'input', 'content'}),
      );

  if (!flagged && !textual && !placeholderTyping) return null;

  final field =
      _findString(
        decodedResult,
        _fieldKeys,
        limit: BrowserSessionLimits.labelCharacters,
      ) ??
      _findString(
        decodedInput,
        _fieldKeys,
        limit: BrowserSessionLimits.labelCharacters,
      ) ??
      _findString(decodedInput, const {
        'selector',
        'ref',
        'element_id',
      }, limit: BrowserSessionLimits.labelCharacters);
  final question = _findString(
    decodedResult,
    _questionKeys,
    limit: BrowserSessionLimits.detailCharacters,
  );

  final haystack = '${field ?? ''} ${question ?? ''} ${resultText ?? ''}';
  return BrowserInputRequest.build(
    stepId: stepId,
    field: field,
    // A plain-text result IS the explanation when the tool gave no structured
    // question; a placeholder-typing request has nothing to quote.
    question:
        question ??
        (textual && decodedResult is String ? decodedResult.trim() : null),
    url: url,
    secret: _secretFieldRe.hasMatch(haystack),
  );
}

/// Best-effort JSON rendering used only for substring matching. Never shown to
/// the user and never allowed to throw on a cyclic or exotic payload.
String? jsonEncodeSafe(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  try {
    return jsonEncode(value);
  } catch (_) {
    try {
      return value.toString();
    } catch (_) {
      return null;
    }
  }
}
