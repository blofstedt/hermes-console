import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: Strings.localizationsDelegates,
    supportedLocales: Strings.supportedLocales,
    theme: AppTheme.fromMode(AppThemeMode.dark),
    home: Scaffold(body: child),
  );

  testWidgets('ChatApprovalCard pinta título, comando y los 4 alcances', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(
      host(
        // companion: null → cae al icono de candado (sin depender de assets).
        ChatApprovalCard(
          approval: const {
            'command': 'ls -la /home',
            'description': 'run_shell',
          },
          busy: false,
          onChoice: taps.add,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Hermes pide tu permiso'), findsOneWidget);
    expect(find.text('ls -la /home'), findsOneWidget);
    // Acciones principales + alcances ampliados.
    expect(find.text('Permitir'), findsOneWidget);
    expect(find.text('Denegar'), findsOneWidget);
    expect(find.text('Esta sesión'), findsOneWidget);
    expect(find.text('Siempre'), findsOneWidget);

    await tester.tap(find.text('Permitir'));
    await tester.tap(find.text('Siempre'));
    expect(taps, ['once', 'always']);
  });

  testWidgets('el comando se puede copiar (formato código)', (tester) async {
    // Interceptamos el canal del portapapeles para verificar el copiado.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await tester.pumpWidget(
      host(
        ChatApprovalCard(
          approval: const {
            'command': 'rm -f /tmp/x',
            'description': 'run_shell',
          },
          busy: false,
          onChoice: (_) {},
        ),
      ),
    );
    await tester.pump();

    // El botón de copiar de la caja del comando (icono content_copy).
    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();
    expect(copied, 'rm -f /tmp/x');
    // Drena el temporizador de 900 ms que repone el icono (evita "Timer pending").
    await tester.pump(const Duration(seconds: 1));

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets('busy bloquea las pulsaciones', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(
      host(
        ChatApprovalCard(
          approval: const {'command': 'rm -rf x'},
          busy: true,
          onChoice: taps.add,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Permitir'));
    expect(taps, isEmpty);
  });

  testWidgets(
    'muestra la herramienta aparte cuando difiere de la descripción',
    (tester) async {
      await tester.pumpWidget(
        host(
          ChatApprovalCard(
            approval: const {
              'command': 'curl https://example.com',
              'tool': 'http_fetch',
              'description': 'Fetch a URL from the web',
            },
            busy: false,
            onChoice: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('http_fetch'), findsOneWidget);
      expect(find.text('Fetch a URL from the web'), findsOneWidget);
    },
  );

  testWidgets('bajo YOLO no añade la etiqueta extra de herramienta', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        ChatApprovalCard(
          approval: const {
            'command': 'curl https://example.com',
            'tool': 'http_fetch',
            'description': 'Fetch a URL from the web',
          },
          busy: false,
          onChoice: (_) {},
          isYolo: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('http_fetch'), findsNothing);
    expect(find.text('Fetch a URL from the web'), findsOneWidget);
  });
}
