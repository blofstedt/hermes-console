// Deriva una vista de "flowchart" del turno activo a partir del trace del
// agente principal y de la actividad de subagentes ya existentes en
// ActiveChat. No introduce un segundo modelo de eventos: solo reproyecta
// `ChatTraceEvent`/`SubagentActivity` en nodos/aristas para el panel visual
// (spec: Agent Flow Panel). Archivo puro (sin Flutter) para poder testearlo
// con `test()` normal, igual que `subagent_activity_reducer.dart`.

import '../models/subagent_activity.dart';
import '../widgets/chat_event_cards.dart' show ChatTraceEvent;

/// Forma real de diagrama de flujo para cada nodo.
enum AgentFlowNodeShape {
  /// Óvalo/estadio: inicio o fin del flujo.
  terminal,

  /// Rectángulo: paso de pensamiento o llamada a herramienta.
  process,

  /// Rombo: punto de decisión (aprobación pendiente o bifurcación a
  /// subagentes).
  decision,

  /// Rectángulo con barras dobles: llamada a un subproceso (subagente).
  subroutine,
}

/// Estado visual de un nodo, independiente de su forma.
enum AgentFlowNodePhase { pending, active, done, error }

/// Un paso del turno proyectado como nodo del flowchart.
final class AgentFlowNode {
  final String id;
  final AgentFlowNodeShape shape;
  final String label;
  final AgentFlowNodePhase phase;

  /// 0 = columna principal del turno; 1..n = carriles paralelos de
  /// subagentes que cuelgan del nodo de bifurcación.
  final int laneIndex;

  final String? detail;
  final String? previewText;
  final double? durationSeconds;
  final SubagentUsage? usage;

  const AgentFlowNode({
    required this.id,
    required this.shape,
    required this.label,
    required this.phase,
    this.laneIndex = 0,
    this.detail,
    this.previewText,
    this.durationSeconds,
    this.usage,
  });
}

/// Conexión dirigida entre dos nodos del flowchart.
final class AgentFlowEdge {
  final String fromId;
  final String toId;

  const AgentFlowEdge({required this.fromId, required this.toId});
}

/// Grafo derivado, listo para pintar. Se reconstruye por completo en cada
/// evento del turno (barato: el trace/actividad de subagentes de un turno
/// nunca es grande), no se difía nodo a nodo entre turnos.
final class AgentFlowGraph {
  final List<AgentFlowNode> nodes;
  final List<AgentFlowEdge> edges;

  /// Nodo que representa "dónde está el agente ahora": el último activo, o
  /// el último nodo si ninguno está marcado activo. Guía el auto-scroll y el
  /// resaltado pulsante del panel.
  final String? currentNodeId;

  const AgentFlowGraph({
    required this.nodes,
    required this.edges,
    this.currentNodeId,
  });

  static const AgentFlowGraph empty = AgentFlowGraph(nodes: [], edges: []);

  bool get isEmpty => nodes.isEmpty;

  AgentFlowNode? nodeById(String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }
}

/// Construye el grafo del turno activo.
///
/// [isYolo] lo calcula quien llama (vía
/// `ApprovalPolicyService.effectiveMode(sessionId) == ApprovalMode.yolo`) —
/// esta función nunca infiere YOLO de `pendingApproval`, porque ese campo
/// puede quedar en `true` un frame durante el auto-approve (ver
/// `ActiveChat._handleApprovalRequest`). Con YOLO el nodo de aprobación se
/// construye ya resuelto (`done`), nunca `active`/pendiente.
AgentFlowGraph buildAgentFlow({
  required List<ChatTraceEvent> trace,
  required List<SubagentActivity> subagents,
  required Map<String, dynamic>? pendingApproval,
  required bool isYolo,
  required bool turnActive,
}) {
  final noActivity =
      trace.isEmpty &&
      subagents.isEmpty &&
      pendingApproval == null &&
      !turnActive;
  if (noActivity) return AgentFlowGraph.empty;

  final nodes = <AgentFlowNode>[];
  final edges = <AgentFlowEdge>[];
  var previousId = 'start';

  void link(String toId) {
    edges.add(AgentFlowEdge(fromId: previousId, toId: toId));
    previousId = toId;
  }

  nodes.add(
    const AgentFlowNode(
      id: 'start',
      shape: AgentFlowNodeShape.terminal,
      label: 'Start',
      phase: AgentFlowNodePhase.done,
    ),
  );

  for (var i = 0; i < trace.length; i++) {
    final event = trace[i];
    final id = 'trace-$i-${event.id}';
    final phase = event.isFailed
        ? AgentFlowNodePhase.error
        : event.isDone
        ? AgentFlowNodePhase.done
        : AgentFlowNodePhase.active;
    nodes.add(
      AgentFlowNode(
        id: id,
        shape: AgentFlowNodeShape.process,
        label: event.label,
        phase: phase,
        previewText: event.preview.isEmpty ? null : event.preview,
      ),
    );
    link(id);
  }

  if (pendingApproval != null) {
    const id = 'approval-gate';
    nodes.add(
      AgentFlowNode(
        id: id,
        shape: AgentFlowNodeShape.decision,
        label: isYolo ? 'Auto-approved' : 'Awaiting approval',
        phase: isYolo ? AgentFlowNodePhase.done : AgentFlowNodePhase.active,
        detail: isYolo ? 'YOLO mode' : null,
      ),
    );
    link(id);
  }

  if (subagents.isNotEmpty) {
    const fanOutId = 'subagent-fanout';
    final anyActive = subagents.any((activity) => !activity.isTerminal);
    nodes.add(
      AgentFlowNode(
        id: fanOutId,
        shape: AgentFlowNodeShape.decision,
        label: 'Delegating',
        phase: anyActive ? AgentFlowNodePhase.active : AgentFlowNodePhase.done,
      ),
    );
    link(fanOutId);
    final fanOutParentId = previousId;

    for (var i = 0; i < subagents.length; i++) {
      final activity = subagents[i];
      final id = 'subagent-${activity.key.stableId}';
      final phase = switch (activity.phase) {
        SubagentActivityPhase.failed => AgentFlowNodePhase.error,
        SubagentActivityPhase.completed ||
        SubagentActivityPhase.cancelled ||
        SubagentActivityPhase.unknown => AgentFlowNodePhase.done,
        SubagentActivityPhase.requested ||
        SubagentActivityPhase.running ||
        SubagentActivityPhase.thinking ||
        SubagentActivityPhase.tool => AgentFlowNodePhase.active,
      };
      final label =
          activity.goalPreview ??
          activity.details.activeToolName ??
          'Subagent ${i + 1}';
      nodes.add(
        AgentFlowNode(
          id: id,
          shape: AgentFlowNodeShape.subroutine,
          label: label,
          phase: phase,
          laneIndex: i + 1,
          detail: activity.resultPreview,
          previewText: activity.details.detailPreview,
          durationSeconds: activity.details.durationSeconds,
          usage: activity.usage,
        ),
      );
      edges.add(AgentFlowEdge(fromId: fanOutParentId, toId: id));
    }
    // Las siguientes ramas de la columna principal (p.ej. el nodo final)
    // deben colgar del nodo de bifurcación, no del último subagente listado.
    previousId = fanOutParentId;
  }

  if (!turnActive) {
    final anyTraceFailed = trace.any((event) => event.isFailed);
    final anySubagentFailed = subagents.any(
      (activity) => activity.phase == SubagentActivityPhase.failed,
    );
    final failed = anyTraceFailed || anySubagentFailed;
    const id = 'end';
    nodes.add(
      AgentFlowNode(
        id: id,
        shape: AgentFlowNodeShape.terminal,
        label: failed ? 'Failed' : 'Done',
        phase: failed ? AgentFlowNodePhase.error : AgentFlowNodePhase.done,
      ),
    );
    link(id);
  }

  return AgentFlowGraph(
    nodes: nodes,
    edges: edges,
    currentNodeId: _resolveCurrentNodeId(nodes),
  );
}

String? _resolveCurrentNodeId(List<AgentFlowNode> nodes) {
  if (nodes.isEmpty) return null;
  for (final node in nodes.reversed) {
    if (node.phase == AgentFlowNodePhase.active) return node.id;
  }
  return nodes.last.id;
}
