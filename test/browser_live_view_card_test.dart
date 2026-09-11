import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/browser_stream_client.dart';
import 'package:hermes_android/core/widgets/browser_live_stream_view.dart';
import 'package:http/http.dart' as http;
import 'package:hermes_android/core/models/browser_session.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/browser_live_view_card.dart';
import 'package:hermes_android/core/widgets/hermes_ui.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// A 1×1 PNG, as a browser tool hands one back.
const String _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
    'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

BrowserFrame _frame([String source = _png]) => BrowserFrame(
  kind: BrowserFrameKind.dataUri,
  source: source,
  capturedAt: DateTime.utc(2026, 1, 1),
);

/// A real 1×1 JPEG, so the viewport can actually decode what the stream sends.
const String _jpegBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
    'AAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

/// One frame, wrapped the way an MJPEG server wraps it.
List<int> _jpegPart() => <int>[
  ...'--b\r\nContent-Type: image/jpeg\r\n\r\n'.codeUnits,
  ...base64Decode(_jpegBase64),
  ...'\r\n'.codeUnits,
];

/// An http client that answers one MJPEG request and then holds the stream
/// open, as a real one does.
class _StreamingClient extends http.BaseClient {
  final List<String> requested = <String>[];
  final int status;

  _StreamingClient({this.status = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requested.add(request.url.toString());
    return http.StreamedResponse(
      Stream<List<int>>.value(_jpegPart()),
      status,
      request: request,
    );
  }
}

void main() {
  Widget host(Widget child) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.hermesRedDark,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  testWidgets('draws nothing until the browser has done something', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const BrowserLiveViewCard(session: BrowserSessionState.empty)),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('Live'), findsNothing);
  });

  testWidgets('shows the page, the frame and the step in flight', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: BrowserSessionState(
            steps: const [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.navigate,
                status: BrowserStepStatus.running,
                target: 'example.com',
              ),
            ],
            frames: [_frame()],
            url: 'https://example.com/login',
            title: 'Sign in',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('https://example.com/login'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // A running step is what makes the card read as live.
    expect(find.text('LIVE'), findsOneWidget);
    // The viewport is cut to the browser's own 16:9 shape and the frame
    // FILLS it, centred: that is what keeps a frame whose aspect ratio does
    // not quite match from being letterboxed against a black bar.
    final viewport = tester.widget<AspectRatio>(
      find
          .ancestor(
            of: find.byType(BrowserFrameImage),
            matching: find.byType(AspectRatio),
          )
          .first,
    );
    expect(viewport.aspectRatio, closeTo(16 / 9, 0.0001));
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
    expect(
      tester.widget<Image>(find.byType(Image)).alignment,
      Alignment.center,
    );
  });

  testWidgets('a finished session reads as idle', (tester) async {
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: const BrowserSessionState(
            steps: [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.click,
                status: BrowserStepStatus.done,
                target: 'Submit',
              ),
            ],
            url: 'https://example.com/',
          ),
        ),
      ),
    );
    expect(find.text('IDLE'), findsOneWidget);
    expect(find.textContaining('Clicked'), findsOneWidget);
    // Nothing is coming: the turn is over and no frame ever arrived, so
    // "Waiting for the first frame…" would be a promise the card cannot
    // keep.
    expect(find.text('Browser inactive'), findsOneWidget);
    expect(find.text('Waiting for the first frame…'), findsNothing);
  });

  testWidgets('a busy session with no frame yet is still waiting', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const BrowserLiveViewCard(
          session: BrowserSessionState(
            steps: [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.navigate,
                status: BrowserStepStatus.running,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Waiting for the first frame…'), findsOneWidget);
    expect(find.text('Browser inactive'), findsNothing);
  });

  testWidgets('the step timeline collapses to the newest step', (tester) async {
    final session = BrowserSessionState(
      steps: List<BrowserStep>.generate(
        4,
        (i) => BrowserStep(
          id: 'c$i',
          action: BrowserAction.click,
          status: BrowserStepStatus.done,
          target: 'button-$i',
        ),
      ),
    );
    await tester.pumpWidget(host(BrowserLiveViewCard(session: session)));

    expect(find.textContaining('button-3'), findsOneWidget);
    expect(find.textContaining('button-0'), findsNothing);

    await tester.tap(find.text('Show 3 more steps'));
    await tester.pump();
    expect(find.textContaining('button-0'), findsOneWidget);

    // The toggle has to survive expansion, or the list can never close again.
    await tester.tap(find.text('Hide steps'));
    await tester.pump();
    expect(find.textContaining('button-0'), findsNothing);
  });

  testWidgets('asks for a value and hands it to the agent', (tester) async {
    String? delivered;
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: const BrowserSessionState(
            steps: [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.type,
                status: BrowserStepStatus.done,
                target: 'Email',
              ),
            ],
            inputRequest: BrowserInputRequest(
              stepId: 'c1',
              field: 'Email',
              question: 'Sign in to continue',
            ),
          ),
          onSubmitInput: (value) => delivered = value,
        ),
      ),
    );

    expect(find.text('Hermes needs something from you'), findsOneWidget);
    expect(find.text('Sign in to continue'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  bob@example.com  ');
    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(delivered, 'bob@example.com');
  });

  testWidgets('a secret field is obscured and says where the value goes', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const BrowserLiveViewCard(
          session: BrowserSessionState(
            steps: [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.type,
                status: BrowserStepStatus.done,
                target: 'Password',
              ),
            ],
            inputRequest: BrowserInputRequest(
              stepId: 'c1',
              field: 'Password',
              secret: true,
            ),
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    // Nothing here reaches the gateway's secret channel, and the card must not
    // imply otherwise.
    expect(
      find.text(
        'This is sent to your agent as a message in this conversation.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an empty answer is not delivered', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: const BrowserSessionState(
            steps: [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.click,
                status: BrowserStepStatus.done,
              ),
            ],
            inputRequest: BrowserInputRequest(stepId: 'c1'),
          ),
          onSubmitInput: (_) => calls++,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('scrubbing back holds while a newer frame arrives', (
    tester,
  ) async {
    final older = _frame();
    final newer = _frame('${_png}A');
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: BrowserSessionState(steps: const [], frames: [older, newer]),
        ),
      ),
    );
    await tester.pump();

    // Two frames put the scrubber on screen, and the newest is what shows, so
    // there is nothing to jump back to yet.
    expect(
      find.byKey(const ValueKey<String>('browser-frame-dot-0')),
      findsOneWidget,
    );
    expect(find.text('Jump to latest'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('browser-frame-dot-0')));
    await tester.pump();
    expect(find.text('Jump to latest'), findsOneWidget);

    // Returning to the live edge retires the affordance again.
    await tester.tap(find.text('Jump to latest'));
    await tester.pump();
    expect(find.text('Jump to latest'), findsNothing);
  });

  testWidgets('opens the live view while the browser is working', (
    tester,
  ) async {
    final client = _StreamingClient();
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: BrowserSessionState(
            steps: const [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.click,
                status: BrowserStepStatus.running,
              ),
            ],
            frames: [_frame()],
          ),
          streamCandidates: const ['http://10.0.0.5:8090/stream'],
          streamClient: BrowserStreamClient(httpClient: client),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(client.requested, ['http://10.0.0.5:8090/stream']);
    // A streaming screen is not the same claim as a busy tool, and the badge
    // says which one the user is looking at.
    expect(find.text('LIVE VIEW'), findsOneWidget);
    // Same guard as the static-frame path: a stream frame fills the 16:9
    // viewport from its centre rather than sitting inside black bars.
    final streamed = tester.widget<Image>(find.byType(Image));
    expect(streamed.fit, BoxFit.cover);
    expect(streamed.alignment, Alignment.center);
  });

  testWidgets('an address the server advertised is tried first', (
    tester,
  ) async {
    final client = _StreamingClient();
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: const BrowserSessionState(
            steps: [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.click,
                status: BrowserStepStatus.running,
              ),
            ],
            streamUrl: 'http://10.0.0.5:9000/live.mjpg',
          ),
          streamCandidates: const ['http://10.0.0.5:8090/stream'],
          streamClient: BrowserStreamClient(httpClient: client),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(client.requested.first, 'http://10.0.0.5:9000/live.mjpg');
  });

  testWidgets('the live view stays open once the steps stop', (tester) async {
    // The viewport is meant to be the browser's ACTIVE tab, and a browser
    // between two tool calls — or after the last one — is still parked on a
    // real page. Closing the stream the moment no step was in flight blanked
    // the card at the one moment the user most wants to see where the run
    // ended up.
    final client = _StreamingClient();
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: BrowserSessionState(
            steps: const [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.click,
                status: BrowserStepStatus.done,
              ),
            ],
            frames: [_frame()],
          ),
          streamCandidates: const ['http://10.0.0.5:8090/stream'],
          streamClient: BrowserStreamClient(httpClient: client),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(client.requested, ['http://10.0.0.5:8090/stream']);
    expect(find.byType(BrowserLiveStreamView), findsOneWidget);
  });

  testWidgets('scrubbing back to an earlier frame closes the live view', (
    tester,
  ) async {
    // Someone reading step 1 is reading history, not watching a screen.
    final client = _StreamingClient();
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: BrowserSessionState(
            steps: const [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.click,
                status: BrowserStepStatus.running,
              ),
            ],
            frames: [_frame(), _frame()],
          ),
          streamCandidates: const ['http://10.0.0.5:8090/stream'],
          streamClient: BrowserStreamClient(httpClient: client),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(BrowserLiveStreamView), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('browser-frame-dot-0')));
    await tester.pump();
    expect(find.byType(BrowserLiveStreamView), findsNothing);
  });

  testWidgets('a server with no stream falls back to the captured frame', (
    tester,
  ) async {
    // Every candidate 404s: the card must end up showing the still it has,
    // not an empty viewport or a spinner that never stops.
    final client = _StreamingClient(status: 404);
    await tester.pumpWidget(
      host(
        BrowserLiveViewCard(
          session: BrowserSessionState(
            steps: const [
              BrowserStep(
                id: 'c1',
                action: BrowserAction.click,
                status: BrowserStepStatus.running,
              ),
            ],
            frames: [_frame()],
          ),
          streamCandidates: const [
            'http://10.0.0.5:8090/stream',
            'http://10.0.0.5:9119/stream',
          ],
          streamClient: BrowserStreamClient(httpClient: client),
        ),
      ),
    );
    await tester.pump();
    // Long enough for both candidates to spend their attempt budget.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 2));
    }

    expect(client.requested, isNotEmpty);
    expect(find.byType(BrowserLiveStreamView), findsNothing);
    expect(find.byType(BrowserFrameImage), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);
  });

  testWidgets('a turn that ends keeps the screen but drops the busy dot', (
    tester,
  ) async {
    final client = _StreamingClient();
    BrowserSessionState session(BrowserStepStatus status) =>
        BrowserSessionState(
          steps: [
            BrowserStep(id: 'c1', action: BrowserAction.click, status: status),
          ],
          frames: [_frame()],
        );

    Widget card(BrowserStepStatus status) => host(
      BrowserLiveViewCard(
        session: session(status),
        streamCandidates: const ['http://10.0.0.5:8090/stream'],
        streamClient: BrowserStreamClient(httpClient: client),
      ),
    );

    await tester.pumpWidget(card(BrowserStepStatus.running));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('LIVE VIEW'), findsOneWidget);

    // The turn ends. The browser is still parked on its active tab and the
    // screen keeps arriving, so the card goes on showing it — what stops is
    // the claim that the AGENT is working, which the badge carries in its
    // colour and its dot rather than in its label.
    await tester.pumpWidget(card(BrowserStepStatus.done));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('LIVE VIEW'), findsOneWidget);
    expect(find.byType(BrowserLiveStreamView), findsOneWidget);
    final colors = AppTheme.hermesRedDark.hermes;
    final badge = tester.widget<HermesBadge>(find.byType(HermesBadge));
    expect(badge.dot, isFalse);
    expect(badge.color, colors.textDisabled);
  });
}
