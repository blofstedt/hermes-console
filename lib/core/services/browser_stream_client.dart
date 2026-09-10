import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/transport_privacy.dart';

/// Reads an MJPEG stream and hands out one frame at a time.
///
/// The server publishes the browser's screen as `multipart/x-mixed-replace`:
/// one HTTP response that never ends, carrying JPEG after JPEG. Flutter cannot
/// render that on its own — `Image.network` decodes ONE image and stops, so a
/// widget pointed straight at the stream URL shows the first frame at best and
/// usually nothing at all. This client is the missing piece: it holds the
/// response open, cuts frames out of the byte stream, and hands each one to
/// the widget as bytes it can paint.
class BrowserStreamClient {
  /// A stream that has gone quiet for this long is dead, whatever the socket
  /// says. Mobile networks drop a connection without closing it, and the card
  /// would otherwise sit on its last frame forever.
  static const Duration frameTimeout = Duration(seconds: 20);

  /// Longest wait before a reconnect attempt. The first retries are quick so a
  /// blip is invisible; a server that is genuinely down is not hammered.
  static const Duration maxBackoff = Duration(seconds: 15);

  final http.Client _http;
  final bool _ownsClient;

  BrowserStreamClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  /// Frames from [url], reconnecting until the subscription is cancelled.
  ///
  /// [headers] carry whatever auth the endpoint sits behind. A drop is not
  /// forwarded as an error: it is a reconnect, and the card keeps showing its
  /// last good frame meanwhile. [onStatus] reports the transitions so the UI
  /// can say "reconnecting" honestly instead of pretending to be live.
  /// [maxFailedAttempts] bounds how long an address that has never produced a
  /// frame is retried, so a caller working through several candidate URLs is
  /// not stuck on the first one forever. A stream that HAS delivered resets
  /// the count: once an address is known good, it is retried indefinitely.
  Stream<Uint8List> frames(
    String url, {
    Map<String, String> headers = const {},
    ValueChanged<BrowserStreamStatus>? onStatus,
    int? maxFailedAttempts,
  }) async* {
    // Same rule the rest of the app applies to a self-hosted address: a
    // cleartext hop to a public host would put the user's screen — and the
    // token fetching it — on the wire in the clear.
    if (TransportPrivacy.classify(url) ==
        TransportPrivacyClass.publicCleartext) {
      onStatus?.call(BrowserStreamStatus.blocked);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      onStatus?.call(BrowserStreamStatus.blocked);
      return;
    }

    var attempt = 0;
    while (true) {
      onStatus?.call(
        attempt == 0
            ? BrowserStreamStatus.connecting
            : BrowserStreamStatus.reconnecting,
      );
      var delivered = false;
      try {
        await for (final frame in _connectOnce(uri, headers)) {
          if (!delivered) {
            delivered = true;
            attempt = 0;
            onStatus?.call(BrowserStreamStatus.live);
          }
          yield frame;
        }
      } catch (error) {
        // A dropped stream is how a mobile connection normally ends, not a
        // fault worth surfacing: the retry below IS the handling.
        debugPrint('[browser-stream] $url: $error');
      }
      attempt++;
      if (!delivered &&
          maxFailedAttempts != null &&
          attempt >= maxFailedAttempts) {
        // This address has never worked. Ending the stream lets the caller
        // move on to the next candidate instead of retrying a dead one.
        onStatus?.call(BrowserStreamStatus.unavailable);
        return;
      }
      onStatus?.call(BrowserStreamStatus.reconnecting);
      await Future<void>.delayed(_backoffFor(attempt));
    }
  }

  /// 0.5s, 1s, 2s, 4s, 8s, then [maxBackoff].
  static Duration _backoffFor(int attempt) {
    final shift = (attempt - 1).clamp(0, 5);
    final millis = 500 * (1 << shift);
    return Duration(
      milliseconds: millis > maxBackoff.inMilliseconds
          ? maxBackoff.inMilliseconds
          : millis,
    );
  }

  /// One connection's worth of frames. Ends — normally or by throwing — as
  /// soon as the stream stops producing, so the caller can reconnect.
  Stream<Uint8List> _connectOnce(Uri uri, Map<String, String> headers) async* {
    final request = http.Request('GET', uri);
    request.headers.addAll(headers);
    // A stream that never ends must never be buffered whole; `send` hands the
    // body over as it arrives.
    final response = await _http
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      try {
        // Drain so the socket is released before the retry.
        await response.stream.drain<void>();
      } catch (_) {
        // Already broken; nothing to release.
      }
      throw BrowserStreamException(
        'HTTP ${response.statusCode}',
        status: response.statusCode,
      );
    }

    final parser = MjpegParser();
    await for (final chunk in response.stream.timeout(frameTimeout)) {
      // The socket already hands over typed data; the copy is only for the
      // rare client that does not.
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      for (final frame in parser.add(bytes)) {
        yield frame;
      }
    }
  }

  void dispose() {
    if (_ownsClient) _http.close();
  }
}

/// Cuts JPEG frames out of an MJPEG byte stream.
///
/// Frames are found by the JPEG markers themselves (`FFD8` … `FFD9`) rather
/// than by the multipart boundary. Every MJPEG server agrees on the markers;
/// they disagree about boundary spelling, `Content-Length` accuracy and
/// trailing CRLFs, and a parser that trusts the envelope breaks on the first
/// server that is sloppy about it.
///
/// Chunk boundaries mean nothing to the sender, so a marker can be split
/// across two of them; the parser carries one byte of context to catch that.
/// Kept separate from the client so it can be tested without a socket.
class MjpegParser {
  /// Anything larger than this between two markers is not a frame — a
  /// mid-stream resync, or a server sending something else entirely. The
  /// buffer is dropped rather than grown until the app dies.
  static const int maxFrameBytes = 8 * 1024 * 1024;

  static const int _markerPrefix = 0xFF;
  static const int _startMarker = 0xD8;
  static const int _endMarker = 0xD9;

  final List<Uint8List> _held = <Uint8List>[];
  int _heldLength = 0;
  bool _inFrame = false;

  /// True when the previous chunk ended on `FF`: the byte that completes a
  /// marker may be the first of the next chunk.
  bool _danglingPrefix = false;

  /// Frames completed by [chunk]. Usually none or one; a slow reader can see
  /// several at once.
  List<Uint8List> add(Uint8List chunk) {
    final frames = <Uint8List>[];
    var offset = 0;

    while (offset < chunk.length) {
      if (!_inFrame) {
        final start = _find(chunk, _startMarker, offset);
        if (start == _splitMarker) {
          // The `FF` was the last byte of the previous chunk, so the frame
          // starts one byte before this one does.
          _inFrame = true;
          _reset();
          _append(Uint8List.fromList(<int>[_markerPrefix]));
          offset = 0;
          continue;
        }
        if (start < 0) {
          // Envelope — headers, boundary, blank lines — and nothing to keep.
          _danglingPrefix = chunk.isNotEmpty && chunk.last == _markerPrefix;
          return frames;
        }
        _inFrame = true;
        _reset();
        offset = start;
      }

      final end = _find(chunk, _endMarker, offset);
      if (end == _splitMarker) {
        // The frame ended on the first byte of this chunk; the `FF` is already
        // held. Take that one byte and close it.
        _append(Uint8List.sublistView(chunk, 0, 1));
        frames.add(_take());
        offset = 1;
        continue;
      }
      if (end < 0) {
        _append(Uint8List.sublistView(chunk, offset));
        _danglingPrefix = chunk.isNotEmpty && chunk.last == _markerPrefix;
        if (_heldLength > maxFrameBytes) _drop();
        return frames;
      }
      // `end` points at the FF of FFD9; the frame includes both bytes.
      _append(Uint8List.sublistView(chunk, offset, end + 2));
      frames.add(_take());
      offset = end + 2;
    }

    _danglingPrefix = chunk.isNotEmpty && chunk.last == _markerPrefix;
    return frames;
  }

  /// Returned by [_find] when the marker straddles the chunk boundary.
  static const int _splitMarker = -2;

  /// Index of `FF <second>` in [bytes] at or after [from]; [_splitMarker] when
  /// the pair began at the end of the previous chunk; -1 when absent.
  int _find(Uint8List bytes, int second, int from) {
    if (_danglingPrefix && from == 0 && bytes.isNotEmpty) {
      _danglingPrefix = false;
      if (bytes[0] == second) return _splitMarker;
    }
    for (var i = from < 0 ? 0 : from; i + 1 < bytes.length; i++) {
      if (bytes[i] == _markerPrefix && bytes[i + 1] == second) return i;
    }
    return -1;
  }

  void _append(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _held.add(bytes);
    _heldLength += bytes.length;
  }

  void _reset() {
    _held.clear();
    _heldLength = 0;
  }

  void _drop() {
    _reset();
    _inFrame = false;
  }

  /// Materialises the held chunks into one frame. The only copy of a frame's
  /// bytes the parser makes, and it happens once per frame.
  Uint8List _take() {
    final frame = Uint8List(_heldLength);
    var at = 0;
    for (final part in _held) {
      frame.setRange(at, at + part.length, part);
      at += part.length;
    }
    _drop();
    return frame;
  }
}

/// What the stream is doing, for a card that has to say so out loud.
enum BrowserStreamStatus {
  connecting,
  live,
  reconnecting,

  /// Refused before dialling: not a usable address, or cleartext to a public
  /// host. Retrying would not change the answer.
  blocked,

  /// Tried and never produced a frame within its attempt budget. The caller
  /// should move on — to another candidate address, or to captured frames.
  unavailable,
}

class BrowserStreamException implements Exception {
  final String message;
  final int? status;

  const BrowserStreamException(this.message, {this.status});

  @override
  String toString() => 'BrowserStreamException: $message';
}
