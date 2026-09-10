import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/approval_activity.dart';
import 'package:hermes_android/core/utils/chat_analytics_summary.dart';

Session _session({
  String id = 's1',
  int inputTokens = 0,
  int outputTokens = 0,
  double? lastActive,
  bool archived = false,
  String? parentSessionId,
}) => Session.fromJson({
  'id': id,
  'input_tokens': inputTokens,
  'output_tokens': outputTokens,
  if (lastActive != null) 'last_active': lastActive,
  'archived': archived,
  if (parentSessionId != null) 'parent_session_id': parentSessionId,
});

ApprovalActivityEntry _entry(String kind, {double ts = 0}) =>
    ApprovalActivityEntry(ts: ts, kind: kind, summary: 'test');

void main() {
  test('empty input yields an empty summary', () {
    final summary = summarizeChatAnalytics(const [], const []);
    expect(summary.sessionCount, 0);
    expect(summary.totalTokens, 0);
    expect(summary.lastActivityAt, isNull);
    expect(summary.autoApproved, 0);
  });

  test('excludes archived and child sessions from the count', () {
    final summary = summarizeChatAnalytics([
      _session(id: 'visible', inputTokens: 10, outputTokens: 5),
      _session(id: 'archived', archived: true, inputTokens: 100),
      _session(id: 'child', parentSessionId: 'visible', inputTokens: 100),
    ], const []);

    expect(summary.sessionCount, 1);
    expect(summary.totalTokens, 15);
  });

  test('picks the most recent lastActivityAt among visible sessions', () {
    final summary = summarizeChatAnalytics([
      _session(id: 'a', lastActive: 100),
      _session(id: 'b', lastActive: 500),
      _session(id: 'c', lastActive: 300),
    ], const []);

    expect(summary.lastActivityAt, 500);
  });

  test('buckets approval kinds into the four summary counters', () {
    final summary = summarizeChatAnalytics(const [], [
      _entry('auto_approved'),
      _entry('yolo_enabled'),
      _entry('allowed_once'),
      _entry('allowed_session'),
      _entry('allowed_always'),
      _entry('denied'),
      _entry('blocked'),
      _entry('yolo_disabled'),
      _entry('requested'), // not counted in any bucket
    ]);

    expect(summary.autoApproved, 2); // auto_approved + yolo_enabled
    expect(summary.approvedManually, 3);
    expect(summary.deniedOrBlocked, 2);
    expect(summary.yoloToggles, 2); // yolo_enabled + yolo_disabled
  });
}
