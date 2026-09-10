import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/agent_flow_builder.dart';
import 'package:hermes_android/core/widgets/agent_flow_panel.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    Strings.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: Strings.supportedLocales,
  home: Scaffold(body: child),
);

AgentFlowGraph _graphWithOneActiveNode() => const AgentFlowGraph(
  nodes: [
    AgentFlowNode(
      id: 'start',
      shape: AgentFlowNodeShape.terminal,
      label: 'Start',
      phase: AgentFlowNodePhase.done,
    ),
    AgentFlowNode(
      id: 'trace-0',
      shape: AgentFlowNodeShape.process,
      label: 'Reading a file',
      phase: AgentFlowNodePhase.active,
      previewText: 'cat notes.md',
    ),
  ],
  edges: [AgentFlowEdge(fromId: 'start', toId: 'trace-0')],
  currentNodeId: 'trace-0',
);

void main() {
  testWidgets('renders nothing for an empty graph', (tester) async {
    await tester.pumpWidget(
      _app(
        const AgentFlowPanel(graph: AgentFlowGraph.empty, turnActive: false),
      ),
    );
    expect(find.byType(AgentFlowPanel), findsOneWidget);
    expect(find.text('Agent flow'), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('collapsed strip shows the current node label and expands on tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AgentFlowPanel(graph: _graphWithOneActiveNode(), turnActive: false),
      ),
    );
    await tester.pump();

    expect(find.text('Reading a file'), findsOneWidget);
    // Collapsed: no scrollable canvas yet.
    expect(find.byType(SingleChildScrollView), findsNothing);

    await tester.tap(find.text('Reading a file'));
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('collapsed panel never animates, even during a live turn', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AgentFlowPanel(graph: _graphWithOneActiveNode(), turnActive: true),
      ),
    );
    // Regression guard: the pulse controller used to repeat forever whenever
    // the turn was live, even collapsed where nothing reads it — which burned
    // frames on device and made this settle time out.
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsNothing);
  });

  testWidgets('expanded panel pulses while the turn is live', (tester) async {
    await tester.pumpWidget(
      _app(
        AgentFlowPanel(graph: _graphWithOneActiveNode(), turnActive: true),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Reading a file'));
    // Past the finite expand animation, so anything still scheduled is the
    // repeating pulse rather than AnimatedSize settling.
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    // Collapse again so the ticker is idle at teardown.
    await tester.tap(find.text('Reading a file'));
    await tester.pumpAndSettle();
  });

  testWidgets('tapping a node invokes onNodeTap with that node', (
    tester,
  ) async {
    AgentFlowNode? tapped;
    final graph = _graphWithOneActiveNode();
    await tester.pumpWidget(
      _app(
        AgentFlowPanel(
          graph: graph,
          turnActive: false,
          onNodeTap: (node) => tapped = node,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Reading a file'));
    await tester.pumpAndSettle();

    // 'trace-0' is the second main-spine node: layout constants from
    // _AgentFlowLayout give it local center (182, 52) inside the canvas.
    final canvas = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(CustomPaint),
    );
    final canvasTopLeft = tester.getTopLeft(canvas.first);
    await tester.tapAt(canvasTopLeft + const Offset(182, 52));
    await tester.pump();

    expect(tapped?.id, 'trace-0');
  });
}
