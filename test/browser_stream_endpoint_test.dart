import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';

SavedConnection _conn({
  String host = '10.0.0.5',
  int port = 8642,
  bool useHttps = false,
  String? dashboardUrl,
  String? browserStreamUrl,
}) => SavedConnection(
  id: 'i1',
  label: 'box',
  host: host,
  port: port,
  apiKey: 'k',
  useHttps: useHttps,
  dashboardUrl: dashboardUrl,
  browserStreamUrl: browserStreamUrl,
);

void main() {
  group('browser stream candidates', () {
    test('an address the user set is the only one tried', () {
      // Nothing is guessed once someone has said where the stream is: probing
      // other ports behind their back is how a firewall log fills up.
      final candidates = _conn(
        browserStreamUrl: 'https://box.ts.net/browser/stream',
      ).browserStreamCandidates;
      expect(candidates, ['https://box.ts.net/browser/stream']);
    });

    test('a bare host:port from the user is still usable', () {
      expect(
        _conn(browserStreamUrl: '10.0.0.9:8090/stream').browserStreamCandidates,
        ['http://10.0.0.9:8090/stream'],
      );
    });

    test('without one, the usual places are tried in order', () {
      final candidates = _conn().browserStreamCandidates;
      // The service's own port first, then the routes a reverse proxy would
      // publish it on.
      expect(candidates.first, 'http://10.0.0.5:8090/stream');
      expect(candidates, contains('http://10.0.0.5:9119/stream'));
      expect(candidates, contains('http://10.0.0.5:8642/stream'));
    });

    test('an https deployment keeps its scheme', () {
      final candidates = _conn(
        host: 'box.example.com',
        port: 443,
        useHttps: true,
      ).browserStreamCandidates;
      expect(candidates.every((url) => url.startsWith('https://')), isTrue);
    });

    test('an explicit dashboard address is where the proxy route is tried', () {
      final candidates = _conn(
        dashboardUrl: 'https://hermes.ts.net',
      ).browserStreamCandidates;
      expect(candidates, contains('https://hermes.ts.net/stream'));
    });

    test('the same address is never tried twice', () {
      final candidates = _conn().browserStreamCandidates;
      expect(candidates.toSet().length, candidates.length);
    });
  });

  group('persistence', () {
    test('a configured stream address survives a save and load', () {
      final saved = _conn(browserStreamUrl: 'http://10.0.0.5:8090/stream');
      final restored = SavedConnection.fromMap(saved.toMap());
      expect(restored.browserStreamUrl, 'http://10.0.0.5:8090/stream');
    });

    test('an instance saved before the field existed still loads', () {
      final legacy = _conn().toMap()..remove('browser_stream_url');
      final restored = SavedConnection.fromMap(legacy);
      expect(restored.browserStreamUrl, isNull);
      expect(restored.browserStreamCandidates, isNotEmpty);
    });

    test('copyWith carries it', () {
      final updated = _conn().copyWith(
        browserStreamUrl: 'http://10.0.0.5:8090/stream',
      );
      expect(updated.browserStreamUrl, 'http://10.0.0.5:8090/stream');
    });
  });
}
