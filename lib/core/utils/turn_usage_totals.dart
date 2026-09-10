// Agrega el uso/costo de los subagentes de un turno. Los números por
// subagente ya vienen resueltos en `SubagentActivity.usage`
// (`subagent_activity.dart`) — esto solo los suma, no introduce una fuente
// de datos nueva.

import '../models/subagent_activity.dart';

/// Totales agregados de todos los subagentes de un turno. `null` en un campo
/// significa "ningún subagente publicó ese dato", no cero.
final class SubagentUsageTotals {
  final int? inputTokens;
  final int? outputTokens;
  final int? apiCalls;
  final double? costUsd;
  final int subagentCount;

  const SubagentUsageTotals({
    required this.subagentCount,
    this.inputTokens,
    this.outputTokens,
    this.apiCalls,
    this.costUsd,
  });

  static const empty = SubagentUsageTotals(subagentCount: 0);

  bool get isEmpty => subagentCount == 0;
}

SubagentUsageTotals totalSubagentUsage(List<SubagentActivity> activities) {
  int? inputTokens;
  int? outputTokens;
  int? apiCalls;
  double? costUsd;

  for (final activity in activities) {
    final usage = activity.usage;
    if (usage == null) continue;
    if (usage.inputTokens != null) {
      inputTokens = (inputTokens ?? 0) + usage.inputTokens!;
    }
    if (usage.outputTokens != null) {
      outputTokens = (outputTokens ?? 0) + usage.outputTokens!;
    }
    if (usage.apiCalls != null) {
      apiCalls = (apiCalls ?? 0) + usage.apiCalls!;
    }
    if (usage.costUsd != null) {
      costUsd = (costUsd ?? 0) + usage.costUsd!;
    }
  }

  return SubagentUsageTotals(
    subagentCount: activities.length,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    apiCalls: apiCalls,
    costUsd: costUsd,
  );
}
