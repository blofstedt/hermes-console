// Heurística local (sin llamadas al servidor) para sugerir una pausa cuando
// el turno actual escala en complejidad: muchas llamadas a herramientas,
// fallos repetidos, o un mensaje en borrador inusualmente largo. Es solo una
// señal para el usuario, no un límite — nunca bloquea el envío.

import '../widgets/chat_event_cards.dart' show ChatTraceEvent;

const int pauseSuggestionToolCallThreshold = 8;
const int pauseSuggestionFailureThreshold = 2;
const int pauseSuggestionDraftLengthThreshold = 800;

bool shouldSuggestPause({
  required List<ChatTraceEvent> recentTrace,
  required int draftMessageLength,
}) {
  final failures = recentTrace.where((event) => event.isFailed).length;
  if (failures >= pauseSuggestionFailureThreshold) return true;
  if (recentTrace.length >= pauseSuggestionToolCallThreshold) return true;
  if (draftMessageLength >= pauseSuggestionDraftLengthThreshold) return true;
  return false;
}
