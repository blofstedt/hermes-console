import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/browser_stream_client.dart';
import 'package:http/http.dart' as http;

/// One JPEG: start marker, body, end marker. The body deliberately contains a
/// `FF` that is NOT a marker, which is what real entropy-coded data looks like.
Uint8List _jpeg(int seed, {int body = 32}) => Uint8List.fromList(<int>[
  0xFF, 0xD8,
  for (var i = 0; i < body; i++) (seed + i) & 0xFF,
  0xFF, 0x00,
  0xFF, 0xD9,
]);

/// The envelope an MJPEG server wraps each frame in.
List<int> _part(Uint8List jpeg) => <int>[
  ...'--boundary\r\nContent-Type: image/jpeg\r\n'
      'Content-Length: ${jpeg.length}\r\n\r\n'
      .codeUnits,
  ...jpeg,
  ...'\r\n'.codeUnits,
];

/// Feeds [bytes] to the parser in slices of [size], as a socket would.
List<Uint8List> _feed(List<int> bytes, int size) {
  final parser = MjpegParser();
  final frames = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += size) {
    final end = i + size > bytes.length ? bytes.length : i + size;
    frames.addAll(parser.add(Uint8List.fromList(bytes.sublist(i, end))));
  }
  return frames;
}

void main() {
  group('MjpegParser', () {
    test('cuts a frame out of one multipart part', () {
      final jpeg = _jpeg(1);
      final frames = _feed(_part(jpeg), 4096);
      expect(frames, hasLength(1));
      expect(frames.single, jpeg);
    });

    test('keeps the frames coming across a long stream', () {
      final stream = <int>[
        ...'HTTP preamble\r\n'.codeUnits,
        for (var i = 0; i < 5; i++) ..._part(_jpeg(i * 7)),
      ];
      final frames = _feed(stream, 4096);
      expect(frames, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(frames[i], _jpeg(i * 7), reason: 'frame $i');
      }
    });

    test('survives any chunking, including markers split in half', () {
      // Chunk sizes chosen to land a split between the FF and the D8/D9 of a
      // marker: the sender knows nothing about our chunk boundaries, and a
      // parser that scans each chunk in isolation drops a frame here.
      final stream = <int>[for (var i = 0; i < 4; i++) ..._part(_jpeg(i * 11))];
      for (final size in const [1, 2, 3, 5, 7, 13, 64, 1024]) {
        final frames = _feed(stream, size);
        expect(frames, hasLength(4), reason: 'chunk size $size');
        for (var i = 0; i < 4; i++) {
          expect(frames[i], _jpeg(i * 11), reason: 'chunk size $size, frame $i');
        }
      }
    });

    test('a body byte that looks like a marker does not end the frame', () {
      // FF00 is a stuffed byte inside real JPEG data. Ending the frame there
      // would hand a truncated image to the decoder.
      final jpeg = _jpeg(3, body: 200);
      final frames = _feed(_part(jpeg), 17);
      expect(frames, hasLength(1));
      expect(frames.single.length, jpeg.length);
    });

    test('ignores the envelope around the picture', () {
      final jpeg = _jpeg(9);
      final frames = _feed(_part(jpeg), 8);
      // Boundary, headers and the trailing CRLF are not part of the frame.
      expect(frames.single.first, 0xFF);
      expect(frames.single[1], 0xD8);
      expect(frames.single[frames.single.length - 2], 0xFF);
      expect(frames.single.last, 0xD9);
    });

    test('resyncs instead of growing without bound', () {
      final parser = MjpegParser();
      // A start marker followed by a flood that never ends: the buffer must be
      // dropped, and a later real frame must still be delivered.
      parser.add(Uint8List.fromList(<int>[0xFF, 0xD8]));
      var pushed = 0;
      while (pushed <= MjpegParser.maxFrameBytes) {
        parser.add(Uint8List(64 * 1024));
        pushed += 64 * 1024;
      }
      final jpeg = _jpeg(5);
      final frames = parser.add(Uint8List.fromList(_part(jpeg)));
      expect(frames, hasLength(1));
      expect(frames.single, jpeg);
    });

    test('two frames inside a single chunk both arrive', () {
      final stream = <int>[..._part(_jpeg(1)), ..._part(_jpeg(2))];
      final frames = _feed(stream, stream.length);
      expect(frames, hasLength(2));
      expect(frames[0], _jpeg(1));
      expect(frames[1], _jpeg(2));
    });

    test('a stream that stops mid-frame yields nothing rather than a stub', () {
      final jpeg = _jpeg(4);
      final truncated = _part(jpeg).sublist(0, 20);
      expect(_feed(truncated, 4), isEmpty);
    });
  });

  group('BrowserStreamClient', () {
    test('picks the stream back up after it drops', () async {
      // An MJPEG response ending is the normal way a mobile connection dies.
      // The view must not be left on a frozen frame waiting for a human.
      final client = _FakeHttpClient([
        _oneFrameThenClose(1),
        _oneFrameThenClose(2),
      ]);
      final stream = BrowserStreamClient(httpClient: client);
      final statuses = <BrowserStreamStatus>[];

      final frames = await stream
          .frames('http://10.0.0.5:8090/stream', onStatus: statuses.add)
          .take(2)
          .toList();

      expect(frames, hasLength(2));
      expect(client.requests, hasLength(2));
      expect(statuses, contains(BrowserStreamStatus.reconnecting));
      expect(statuses.last, BrowserStreamStatus.live);
    });

    test('gives up on an address that never answers', () async {
      // So a caller can move on to the next candidate instead of retrying a
      // route the server does not publish.
      final client = _FakeHttpClient([], status: 404);
      final stream = BrowserStreamClient(httpClient: client);
      final statuses = <BrowserStreamStatus>[];

      final frames = await stream
          .frames(
            'http://10.0.0.5:8090/stream',
            maxFailedAttempts: 2,
            onStatus: statuses.add,
          )
          .toList();

      expect(frames, isEmpty);
      expect(client.requests, hasLength(2));
      expect(statuses.last, BrowserStreamStatus.unavailable);
    });

    test('refuses to put the screen on the wire in the clear', () async {
      // Cleartext to a public host — the same rule the rest of the app applies
      // to a self-hosted address.
      final client = _FakeHttpClient([]);
      final stream = BrowserStreamClient(httpClient: client);
      final statuses = <BrowserStreamStatus>[];

      final frames = await stream
          .frames('http://example.com/stream', onStatus: statuses.add)
          .toList();

      expect(frames, isEmpty);
      expect(client.requests, isEmpty);
      expect(statuses, [BrowserStreamStatus.blocked]);
    });

    test('a private-network address is allowed', () async {
      final client = _FakeHttpClient([_oneFrameThenClose(1)]);
      final stream = BrowserStreamClient(httpClient: client);
      final frames = await stream
          .frames('http://192.168.1.20:8090/stream')
          .take(1)
          .toList();
      expect(frames, hasLength(1));
    });
  });
}

/// A response body carrying one frame, then ending — a stream that dropped.
Stream<List<int>> _oneFrameThenClose(int seed) =>
    Stream<List<int>>.value(_part(_jpeg(seed)));

class _FakeHttpClient extends http.BaseClient {
  final List<Stream<List<int>>> _bodies;
  final int status;
  final List<String> requests = <String>[];

  _FakeHttpClient(this._bodies, {this.status = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url.toString());
    final body = _bodies.isEmpty
        ? const Stream<List<int>>.empty()
        : _bodies.removeAt(0);
    return http.StreamedResponse(body, status, request: request);
  }
}
