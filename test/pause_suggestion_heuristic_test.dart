import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/pause_suggestion_heuristic.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';

ChatTraceEvent _event({String status = 'completed'}) =>
    ChatTraceEvent(id: 'e', label: 'step', status: status);

void main() {
  test('quiet turn with a short draft never suggests a pause', () {
    expect(
      shouldSuggestPause(recentTrace: const [], draftMessageLength: 20),
      isFalse,
    );
  });

  test('two or more failed steps suggest a pause', () {
    expect(
      shouldSuggestPause(
        recentTrace: [
          _event(status: 'failed'),
          _event(status: 'failed'),
        ],
        draftMessageLength: 0,
      ),
      isTrue,
    );
  });

  test('a long run of tool calls suggests a pause', () {
    final trace = List.generate(
      pauseSuggestionToolCallThreshold,
      (_) => _event(),
    );
    expect(
      shouldSuggestPause(recentTrace: trace, draftMessageLength: 0),
      isTrue,
    );
  });

  test('a very long draft suggests a pause even with a quiet turn', () {
    expect(
      shouldSuggestPause(
        recentTrace: const [],
        draftMessageLength: pauseSuggestionDraftLengthThreshold,
      ),
      isTrue,
    );
  });
}
