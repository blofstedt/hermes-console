// Aviso ligero y descartable que sugiere pausar cuando el turno activo
// escala en complejidad (ver `pause_suggestion_heuristic.dart`). Nunca
// bloquea el envío — es una señal, no un gate.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class PauseSuggestionChip extends StatelessWidget {
  final VoidCallback onDismiss;

  const PauseSuggestionChip({required this.onDismiss, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).hermes;
    final strings = Strings.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        key: const ValueKey('pause-suggestion-chip'),
        padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.pause_circle_outline, size: 16, color: colors.warning),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                strings.pauseSuggestionText,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ),
            IconButton(
              key: const ValueKey('pause-suggestion-dismiss'),
              onPressed: onDismiss,
              tooltip: strings.commonClose,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              icon: Icon(Icons.close_rounded, size: 16, color: colors.textDisabled),
            ),
          ],
        ),
      ),
    );
  }
}
