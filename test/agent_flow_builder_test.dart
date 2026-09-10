import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/utils/agent_flow_builder.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'connection-flow',
  parentSessionId: 'parent-flow',
  runtimeSessionId: 'runtime-flow',
  turnEpoch: 1,
);

ChatTraceEvent _trace({
  String id = 'tool-1',
  String label = 'Reading a file',
  String status = 'running',
  String preview = '',
}) => ChatTraceEvent(id: id, label: label, status: status, preview: preview);

SubagentActivity _subagent({
  String stableId = 'child-1',
  SubagentActivityPhase phase = SubagentActivityPhase.running,
  String? goalPreview = 'Investigate the bug',
}) => SubagentActivity(
  key: SubagentActivityKey(
    scope: _scope,
    identityKind: SubagentIdentityKind.subagent,
    stableId: stableId,
  ),
  source: SubagentActivitySource.native,
  phase: phase,
  subagentId: stableId,
  details: SubagentActivityDetails(goalPreview: goalPreview),
);

void main() {
  group('buildAgentFlow', () {
    test('returns the empty graph when nothing is happening', () {
      final graph = buildAgentFlow(
        trace: const [],
        subagents: const [],
        pendingApproval: null,
        isYolo: false,
        turnActive: false,
      );
      expect(graph.isEmpty, isTrue);
      expect(graph, same(AgentFlowGraph.empty));
    });

    test('an active turn with no events yet still shows the start node', () {
      final graph = buildAgentFlow(
        trace: const [],
        subagents: const [],
        pendingApproval: null,
        isYolo: false,
        turnActive: true,
      );
      expect(graph.isEmpty, isFalse);
      expect(graph.nodes, hasLength(1));
      expect(graph.nodes.single.id, 'start');
      expect(graph.currentNodeId, 'start');
    });

    test('one running trace event becomes an active process node', () {
      final graph = buildAgentFlow(
        trace: [_trace(status: 'running')],
        subagents: const [],
        pendingApproval: null,
        isYolo: false,
        turnActive: true,
      );
      final node = graph.nodes.last;
      expect(node.shape, AgentFlowNodeShape.process);
      expect(node.phase, AgentFlowNodePhase.active);
      expect(graph.currentNodeId, node.id);
    });

    test('YOLO with a pending approval renders the gate as already done', () {
      final graph = buildAgentFlow(
        trace: const [],
        subagents: const [],
        pendingApproval: const {'command': 'rm -rf /tmp/x'},
        isYolo: true,
        turnActive: true,
      );
      final gate = graph.nodeById('approval-gate')!;
      expect(gate.shape, AgentFlowNodeShape.decision);
      expect(gate.phase, AgentFlowNodePhase.done);
      // Never active/pending under YOLO, even though pendingApproval != null.
      expect(gate.phase, isNot(AgentFlowNodePhase.active));
    });

    test('non-YOLO with a pending approval renders the gate as active', () {
      final graph = buildAgentFlow(
        trace: const [],
        subagents: const [],
        pendingApproval: const {'command': 'rm -rf /tmp/x'},
        isYolo: false,
        turnActive: true,
      );
      final gate = graph.nodeById('approval-gate')!;
      expect(gate.phase, AgentFlowNodePhase.active);
      expect(graph.currentNodeId, 'approval-gate');
    });

    test('concurrent subagents fan out into parallel lane nodes', () {
      final graph = buildAgentFlow(
        trace: const [],
        subagents: [
          _subagent(stableId: 'a', phase: SubagentActivityPhase.running),
          _subagent(stableId: 'b', phase: SubagentActivityPhase.completed),
        ],
        pendingApproval: null,
        isYolo: false,
        turnActive: true,
      );
      final fanOut = graph.nodeById('subagent-fanout')!;
      expect(fanOut.shape, AgentFlowNodeShape.decision);
      expect(fanOut.laneIndex, 0);

      final laneA = graph.nodeById('subagent-a')!;
      final laneB = graph.nodeById('subagent-b')!;
      expect(laneA.laneIndex, 1);
      expect(laneA.shape, AgentFlowNodeShape.subroutine);
      expect(laneA.phase, AgentFlowNodePhase.active);
      expect(laneB.laneIndex, 2);
      expect(laneB.phase, AgentFlowNodePhase.done);

      expect(
        graph.edges.where((e) => e.fromId == 'subagent-fanout'),
        hasLength(2),
      );
    });

    test('a failed step at turn end produces an error terminal node', () {
      final graph = buildAgentFlow(
        trace: [_trace(status: 'failed')],
        subagents: const [],
        pendingApproval: null,
        isYolo: false,
        turnActive: false,
      );
      final end = graph.nodeById('end')!;
      expect(end.shape, AgentFlowNodeShape.terminal);
      expect(end.phase, AgentFlowNodePhase.error);
    });

    test('a fully completed turn produces a done terminal node', () {
      final graph = buildAgentFlow(
        trace: [_trace(status: 'completed')],
        subagents: const [],
        pendingApproval: null,
        isYolo: false,
        turnActive: false,
      );
      final end = graph.nodeById('end')!;
      expect(end.phase, AgentFlowNodePhase.done);
    });
  });
}
