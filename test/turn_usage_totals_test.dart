import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/subagent_activity.dart';
import 'package:hermes_android/core/utils/turn_usage_totals.dart';

final SubagentActivityScope _scope = SubagentActivityScope(
  connectionId: 'connection-usage',
  parentSessionId: 'parent-usage',
  runtimeSessionId: 'runtime-usage',
  turnEpoch: 1,
);

SubagentActivity _activity(String stableId, SubagentUsage? usage) =>
    SubagentActivity(
      key: SubagentActivityKey(
        scope: _scope,
        identityKind: SubagentIdentityKind.subagent,
        stableId: stableId,
      ),
      source: SubagentActivitySource.native,
      phase: SubagentActivityPhase.running,
      subagentId: stableId,
      details: SubagentActivityDetails(usage: usage),
    );

void main() {
  test('empty list returns the empty totals', () {
    final totals = totalSubagentUsage(const []);
    expect(totals.isEmpty, isTrue);
    expect(totals.costUsd, isNull);
  });

  test('sums tokens and cost across subagents, ignoring missing fields', () {
    final totals = totalSubagentUsage([
      _activity(
        'a',
        const SubagentUsage(inputTokens: 100, outputTokens: 50, costUsd: 0.01),
      ),
      _activity('b', const SubagentUsage(inputTokens: 20, apiCalls: 3)),
      _activity('c', null),
    ]);

    expect(totals.subagentCount, 3);
    expect(totals.inputTokens, 120);
    expect(totals.outputTokens, 50);
    expect(totals.apiCalls, 3);
    expect(totals.costUsd, closeTo(0.01, 1e-9));
  });
}
