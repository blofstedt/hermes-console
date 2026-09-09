import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/browser_session.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/browser_live_view_card.dart';
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
}
