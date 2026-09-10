// Analíticas de chat — resumen local de sesiones y actividad de
// aprobaciones para esta conexión.
//
// Limitación honesta (ver plan): el gateway no persiste eventos de turno
// (trace/uso por turno) más allá de la sesión activa en memoria, así que
// esto solo agrega lo que YA existe de forma local y duradera:
//   - Sesiones remotas vía `ApiClient.getSessions()` (igual que el drawer).
//   - El registro de aprobaciones `ApprovalActivityLog` (SharedPreferences).
// No se inventa una analítica por turno que el Gateway no publica. La
// agregación en sí vive en `chat_analytics_summary.dart` (pura, testeada
// sin red ni widgets); esta pantalla solo carga los datos y la pinta.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';
import '../services/approval_activity.dart';
import '../services/connection_manager.dart';
import '../theme/app_theme.dart';
import '../utils/chat_analytics_summary.dart';
import '../utils/relative_time.dart';
import '../widgets/accent_card.dart';
import '../widgets/hermes_app_bar.dart';

class ChatAnalyticsScreen extends StatefulWidget {
  final SavedConnection connection;

  const ChatAnalyticsScreen({required this.connection, super.key});

  @override
  State<ChatAnalyticsScreen> createState() => _ChatAnalyticsScreenState();
}

class _ChatAnalyticsScreenState extends State<ChatAnalyticsScreen> {
  bool _loading = true;
  Object? _error;
  ChatAnalyticsSummary? _summary;
  List<ApprovalActivityEntry> _approvals = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final log = ApprovalActivityLog(prefs);
      final client = ApiClient(
        baseUrl: widget.connection.baseUrl,
        apiKey: widget.connection.apiKey,
      );
      final sessions = await client.getSessions();
      final approvals = log.entries(widget.connection.id);
      if (!mounted) return;
      setState(() {
        _summary = summarizeChatAnalytics(sessions, approvals);
        _approvals = approvals;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: HermesAppBar(title: Text(strings.chatAnalyticsTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorState(onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                children: [
                  Text(
                    strings.chatAnalyticsSessionsHeading,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _SessionsCard(summary: _summary!),
                  const SizedBox(height: 20),
                  Text(
                    strings.chatAnalyticsApprovalsHeading,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  _ApprovalsSummaryCard(
                    summary: _summary!,
                    hasEntries: _approvals.isNotEmpty,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    strings.chatAnalyticsRecentHeading,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (_approvals.isEmpty)
                    _EmptyNotice(text: strings.chatAnalyticsEmpty)
                  else
                    _RecentActivityList(
                      entries: _approvals.take(20).toList(),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sync_problem_rounded, size: 28, color: colors.error),
            const SizedBox(height: 10),
            Text(
              strings.chatAnalyticsLoadError,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              child: Text(strings.commonClose),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionsCard extends StatelessWidget {
  final ChatAnalyticsSummary summary;

  const _SessionsCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    if (summary.sessionCount == 0) {
      return _EmptyNotice(text: strings.chatAnalyticsNoSessions);
    }
    final lastActivityAt = summary.lastActivityAt;
    final languageCode = Localizations.localeOf(context).languageCode;
    return AccentCard(
      background: colors.surfaceVariant.withValues(alpha: 0.46),
      borderColor: colors.divider.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatRow(
            label: strings.chatAnalyticsTotalSessions,
            value: '${summary.sessionCount}',
          ),
          _StatRow(
            label: strings.chatAnalyticsTotalTokens,
            value: '${summary.totalTokens}',
          ),
          if (lastActivityAt != null)
            _StatRow(
              label: strings.chatAnalyticsLastActive,
              value: relativeTime(lastActivityAt, languageCode: languageCode),
            ),
        ],
      ),
    );
  }
}

class _ApprovalsSummaryCard extends StatelessWidget {
  final ChatAnalyticsSummary summary;
  final bool hasEntries;

  const _ApprovalsSummaryCard({
    required this.summary,
    required this.hasEntries,
  });

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    final colors = Theme.of(context).hermes;
    if (!hasEntries) {
      return _EmptyNotice(text: strings.chatAnalyticsEmpty);
    }
    return AccentCard(
      background: colors.surfaceVariant.withValues(alpha: 0.46),
      borderColor: colors.divider.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatRow(
            label: strings.chatAnalyticsAutoApproved,
            value: '${summary.autoApproved}',
          ),
          _StatRow(
            label: strings.chatAnalyticsApprovedManually,
            value: '${summary.approvedManually}',
          ),
          _StatRow(
            label: strings.chatAnalyticsDeniedBlocked,
            value: '${summary.deniedOrBlocked}',
          ),
          _StatRow(
            label: strings.chatAnalyticsYoloToggles,
            value: '${summary.yoloToggles}',
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: colors.textSecondary)),
          ),
          Text(
            value,
            style: TextStyle(
              color: colors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentActivityList extends StatelessWidget {
  final List<ApprovalActivityEntry> entries;

  const _RecentActivityList({required this.entries});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final languageCode = Localizations.localeOf(context).languageCode;
    return Column(
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0)
            Divider(
              height: 15,
              color: colors.divider.withValues(alpha: 0.45),
            ),
          _ActivityRow(entry: entries[i], languageCode: languageCode),
        ],
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final ApprovalActivityEntry entry;
  final String languageCode;

  const _ActivityRow({required this.entry, required this.languageCode});

  Color _kindColor(HermesThemeColors colors) => switch (entry.kind) {
    'denied' || 'blocked' => colors.error,
    'auto_approved' || 'yolo_enabled' => colors.warning,
    'allowed_once' || 'allowed_session' || 'allowed_always' => colors.success,
    _ => colors.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final color = _kindColor(colors);
    final kindLabel = entry.kind.replaceAll('_', ' ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.summary.isEmpty ? kindLabel : entry.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textPrimary, fontSize: 12.5),
                ),
                const SizedBox(height: 2),
                Text(
                  '$kindLabel · '
                  '${relativeTime(entry.ts, languageCode: languageCode)}',
                  style: TextStyle(color: color, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyNotice extends StatelessWidget {
  final String text;

  const _EmptyNotice({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(color: colors.textSecondary)),
    );
  }
}
