// Agregación pura para la pantalla de analíticas de chat. Separado del
// widget para poder testearlo con `test()` normal, sin levantar la UI ni
// simular red (ver `chat_analytics_screen.dart`).

import '../models/session.dart';
import '../services/approval_activity.dart';

final class ChatAnalyticsSummary {
  final int sessionCount;
  final int totalTokens;
  final double? lastActivityAt;
  final int autoApproved;
  final int approvedManually;
  final int deniedOrBlocked;
  final int yoloToggles;

  const ChatAnalyticsSummary({
    required this.sessionCount,
    required this.totalTokens,
    required this.lastActivityAt,
    required this.autoApproved,
    required this.approvedManually,
    required this.deniedOrBlocked,
    required this.yoloToggles,
  });
}

const _autoKinds = {'auto_approved', 'yolo_enabled'};
const _manualKinds = {'allowed_once', 'allowed_session', 'allowed_always'};
const _blockedKinds = {'denied', 'blocked'};
const _yoloToggleKinds = {'yolo_enabled', 'yolo_disabled'};

int _count(List<ApprovalActivityEntry> entries, Set<String> kinds) =>
    entries.where((entry) => kinds.contains(entry.kind)).length;

/// Solo cuenta sesiones "reales" visibles (no archivadas, no jobs de
/// Kanban/cron, no hijas de otra sesión) — el mismo filtro que ya usa el
/// drawer para "sesiones recientes".
ChatAnalyticsSummary summarizeChatAnalytics(
  List<Session> sessions,
  List<ApprovalActivityEntry> approvals,
) {
  final visibleSessions = sessions
      .where(
        (session) =>
            !session.archived &&
            !session.isJob &&
            !session.isKanbanJob &&
            session.parentSessionId == null,
      )
      .toList();

  double? lastActivityAt;
  for (final session in visibleSessions) {
    if (lastActivityAt == null || session.lastActivityAt > lastActivityAt) {
      lastActivityAt = session.lastActivityAt;
    }
  }

  return ChatAnalyticsSummary(
    sessionCount: visibleSessions.length,
    totalTokens: visibleSessions.fold<int>(
      0,
      (sum, session) => sum + session.totalTokens,
    ),
    lastActivityAt: lastActivityAt,
    autoApproved: _count(approvals, _autoKinds),
    approvedManually: _count(approvals, _manualKinds),
    deniedOrBlocked: _count(approvals, _blockedKinds),
    yoloToggles: _count(approvals, _yoloToggleKinds),
  );
}
