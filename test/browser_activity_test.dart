import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/browser_session.dart';
import 'package:hermes_android/core/services/browser_activity_reducer.dart';
import 'package:hermes_android/core/utils/browser_activity.dart';

/// A 1×1 PNG, as a browser tool would hand one back.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

BrowserSessionState _fold(
  List<({Map<String, dynamic> payload, bool running})> events,
) {
  var state = BrowserSessionState.empty;
  var sequence = 0;
  for (final event in events) {
    final parsed = BrowserToolEvent.tryParse(
      event.payload,
      running: event.running,
      sequence: event.running ? ++sequence : sequence,
    );
    if (parsed == null) continue;
    state = BrowserActivityReducer.reduce(state, parsed);
  }
  return state;
}

void main() {
  group('tool identity', () {
    test('recognises browser tools across stacks and MCP prefixes', () {
      for (final name in const [
        'browser_navigate',
        'mcp__playwright__browser_click',
        'playwright:browser.type',
        'puppeteer_screenshot',
        'go_to_url',
        'input_text',
        'click_element_by_index',
        'mcp__chrome-devtools__fill',
        'browserbase_session_create',
      ]) {
        expect(isBrowserTool(name), isTrue, reason: name);
      }
    });

    test('leaves non-browser tools alone', () {
      // `click`, `fill` and `screenshot` are desktop and form verbs just as
      // often as browser ones; without a namespace they are not ours.
      for (final name in const [
        'bash',
        'read_file',
        'click',
        'fill',
        'screenshot',
        'take_screenshot',
        'image_generate',
        'delegate_task',
        'web_search',
        null,
        '',
      ]) {
        expect(isBrowserTool(name), isFalse, reason: '$name');
      }
    });

    test('classifies the verb, not the vendor', () {
      expect(classifyBrowserAction('browser_navigate'), BrowserAction.navigate);
      expect(classifyBrowserAction('go_to_url'), BrowserAction.navigate);
      expect(classifyBrowserAction('puppeteer_fill'), BrowserAction.type);
      expect(classifyBrowserAction('input_text'), BrowserAction.type);
      expect(classifyBrowserAction('browser_click'), BrowserAction.click);
      expect(
        classifyBrowserAction('browser_take_screenshot'),
        BrowserAction.screenshot,
      );
      // A more specific token has to beat the generic one it contains.
      expect(
        classifyBrowserAction('browser_navigate_back'),
        BrowserAction.back,
      );
      expect(classifyBrowserAction('browser_wait_for'), BrowserAction.waitFor);
    });
  });

  group('page identity', () {
    test('reads a url from anywhere in the payload', () {
      expect(
        browserUrlFrom({
          'result': {
            'page': {'current_url': 'https://example.com/login'},
          },
        }),
        'https://example.com/login',
      );
    });

    test('rejects a selector parked under a url key', () {
      expect(browserUrlFrom({'url': '#email'}), isNull);
      expect(browserUrlFrom({'url': 'javascript:alert(1)'}), isNull);
      expect(browserUrlFrom({'url': 'file:///etc/passwd'}), isNull);
    });

    test('drops a title that is only the url again', () {
      expect(
        browserTitleFrom({
          'title': 'https://example.com',
        }, url: 'https://example.com'),
        isNull,
      );
      expect(
        browserTitleFrom({'title': 'Sign in'}, url: 'https://example.com'),
        'Sign in',
      );
    });
  });

  group('frames', () {
    final at = DateTime.utc(2026, 1, 1);

    test('accepts a data uri', () {
      final frame = browserFrameFrom({
        'screenshot': 'data:image/png;base64,$_pngBase64',
      }, capturedAt: at);
      expect(frame?.kind, BrowserFrameKind.dataUri);
    });

    test('accepts an MCP image content block', () {
      final frame = browserFrameFrom({
        'content': [
          {'type': 'text', 'text': 'clicked'},
          {'type': 'image', 'data': _pngBase64, 'mimeType': 'image/png'},
        ],
      }, capturedAt: at);
      expect(frame?.kind, BrowserFrameKind.dataUri);
      expect(frame?.source, startsWith('data:image/png;base64,'));
    });

    test('types bare base64 by signature', () {
      final frame = browserFrameFrom({
        'screenshot': _pngBase64,
      }, capturedAt: at);
      expect(frame?.source, 'data:image/png;base64,$_pngBase64');
    });

    test('refuses an opaque blob that is not an image', () {
      // A long token under the generic `data` key must never be rendered.
      expect(browserFrameFrom({'data': 'x' * 400}, capturedAt: at), isNull);
    });

    test('refuses base64 that does not decode', () {
      // Long enough to clear the size floor, so it is the decode that rejects
      // it and not the length check standing in for one.
      final truncated = 'iVBORw0KGgo${'!' * 120}';
      expect(
        browserFrameFrom({'screenshot': truncated}, capturedAt: at),
        isNull,
      );
    });

    test('allows a viewer url on a private network, blocks a public one', () {
      final private = browserFrameFrom({
        'screenshot_url': 'http://umbrel-1.tail16900.ts.net:8091/frame.png',
      }, capturedAt: at);
      expect(private?.kind, BrowserFrameKind.httpUrl);

      // Cleartext to a public host would leak the page contents in the clear,
      // and the app blocks that everywhere else too.
      expect(
        browserFrameFrom({
          'screenshot_url': 'http://example.com/frame.png',
        }, capturedAt: at),
        isNull,
      );
      expect(
        browserFrameFrom({
          'screenshot_url': 'https://example.com/frame.png',
        }, capturedAt: at)?.kind,
        BrowserFrameKind.httpUrl,
      );
    });

    test('a page url is not a frame', () {
      expect(
        browserFrameFrom({'url': 'https://example.com/login'}, capturedAt: at),
        isNull,
      );
    });
  });

  group('input requests', () {
    test('reads a structured flag', () {
      final request = browserInputRequestFrom(
        stepId: 'call-1',
        action: BrowserAction.click,
        result: {'needs_input': true, 'field': 'Email', 'prompt': 'Sign in'},
      );
      expect(request?.field, 'Email');
      expect(request?.question, 'Sign in');
      expect(request?.secret, isFalse);
    });

    test('reads plain prose from a tool that has no schema for it', () {
      final request = browserInputRequestFrom(
        stepId: 'call-1',
        action: BrowserAction.navigate,
        result: 'Login required: please enter your verification code.',
      );
      expect(request, isNotNull);
      // A verification code must arrive marked secret so the field obscures it.
      expect(request!.secret, isTrue);
    });

    test('treats a placeholder value as the agent asking', () {
      final request = browserInputRequestFrom(
        stepId: 'call-1',
        action: BrowserAction.type,
        input: {'selector': '#email', 'text': '<your email>'},
      );
      expect(request, isNotNull);
      expect(request!.field, '#email');
    });

    test('stays quiet on an ordinary step', () {
      expect(
        browserInputRequestFrom(
          stepId: 'call-1',
          action: BrowserAction.click,
          input: {'element': 'Submit'},
          result: {'success': true, 'url': 'https://example.com/next'},
        ),
        isNull,
      );
    });

    test('marks password fields secret', () {
      final request = browserInputRequestFrom(
        stepId: 'call-1',
        action: BrowserAction.type,
        input: {'field': 'Password', 'text': '{{password}}'},
      );
      expect(request?.secret, isTrue);
    });
  });

  group('reducer', () {
    test('pairs start with complete instead of appending twice', () {
      final state = _fold([
        (
          payload: <String, dynamic>{
            'name': 'browser_navigate',
            'tool_call_id': 'c1',
            'input': {'url': 'https://example.com'},
          },
          running: true,
        ),
        (
          payload: <String, dynamic>{
            'name': 'browser_navigate',
            'tool_call_id': 'c1',
            'result': {'url': 'https://example.com/', 'title': 'Example'},
          },
          running: false,
        ),
      ]);

      expect(state.steps, hasLength(1));
      expect(state.steps.single.status, BrowserStepStatus.done);
      expect(state.steps.single.action, BrowserAction.navigate);
      expect(state.url, 'https://example.com/');
      expect(state.title, 'Example');
      expect(state.isBusy, isFalse);
    });

    test('a running step reports the session busy', () {
      final state = _fold([
        (
          payload: <String, dynamic>{
            'name': 'browser_click',
            'tool_call_id': 'c1',
          },
          running: true,
        ),
      ]);
      expect(state.isBusy, isTrue);
      expect(state.steps.single.status, BrowserStepStatus.running);
    });

    test('ignores tools that are not browser tools', () {
      final state = _fold([
        (
          payload: <String, dynamic>{'name': 'bash', 'tool_call_id': 'c1'},
          running: true,
        ),
        (
          payload: <String, dynamic>{'name': 'read_file', 'tool_call_id': 'c2'},
          running: false,
        ),
      ]);
      expect(state.isEmpty, isTrue);
    });

    test('never echoes what was typed into a field', () {
      final state = _fold([
        (
          payload: <String, dynamic>{
            'name': 'browser_type',
            'tool_call_id': 'c1',
            'input': {'element': 'Password', 'text': 'hunter2'},
          },
          running: false,
        ),
      ]);
      expect(state.steps.single.target, 'Password');
      expect(jsonEncode(state.steps.single.target), isNot(contains('hunter2')));
    });

    test('marks a failed step and keeps its reason', () {
      final state = _fold([
        (
          payload: <String, dynamic>{
            'name': 'browser_click',
            'tool_call_id': 'c1',
            'error': 'element not found',
            'result': 'element not found',
          },
          running: false,
        ),
      ]);
      expect(state.steps.single.status, BrowserStepStatus.failed);
      expect(state.steps.single.detail, contains('element not found'));
    });

    test('retains a bounded number of steps', () {
      final state = _fold([
        for (var i = 0; i < BrowserSessionLimits.retainedSteps + 12; i++)
          (
            payload: <String, dynamic>{
              'name': 'browser_click',
              'tool_call_id': 'c$i',
            },
            running: false,
          ),
      ]);
      expect(state.steps, hasLength(BrowserSessionLimits.retainedSteps));
      expect(state.droppedSteps, 12);
    });

    test('retains a bounded number of frames', () {
      final state = _fold([
        for (var i = 0; i < BrowserSessionLimits.retainedFrames + 5; i++)
          (
            payload: <String, dynamic>{
              'name': 'browser_take_screenshot',
              'tool_call_id': 'c$i',
              // Distinct frames: an identical one is deduped by design.
              'result': {'screenshot': 'data:image/png;base64,$_pngBase64$i'},
            },
            running: false,
          ),
      ]);
      expect(state.frames, hasLength(BrowserSessionLimits.retainedFrames));
      expect(state.currentFrame, state.frames.last);
    });

    test('does not push a real frame out for a repeated one', () {
      final state = _fold([
        for (var i = 0; i < 3; i++)
          (
            payload: <String, dynamic>{
              'name': 'browser_take_screenshot',
              'tool_call_id': 'c$i',
              'result': {'screenshot': 'data:image/png;base64,$_pngBase64'},
            },
            running: false,
          ),
      ]);
      expect(state.frames, hasLength(1));
    });

    test('an input request survives until the browser moves on', () {
      var state = _fold([
        (
          payload: <String, dynamic>{
            'name': 'browser_click',
            'tool_call_id': 'c1',
            'result': {'needs_input': true, 'field': 'Email'},
          },
          running: false,
        ),
      ]);
      expect(state.inputRequest?.field, 'Email');

      // The next step means the run is no longer parked on the user.
      state = BrowserActivityReducer.reduce(
        state,
        BrowserToolEvent.tryParse({
          'name': 'browser_click',
          'tool_call_id': 'c2',
        }, running: true)!,
      );
      expect(state.inputRequest, isNull);
    });

    test('clearing an answered request leaves the rest of the state', () {
      final state = _fold([
        (
          payload: <String, dynamic>{
            'name': 'browser_click',
            'tool_call_id': 'c1',
            'result': {'needs_input': true, 'field': 'Email'},
          },
          running: false,
        ),
      ]);
      final cleared = BrowserActivityReducer.clearInputRequest(state);
      expect(cleared.inputRequest, isNull);
      expect(cleared.steps, state.steps);
      expect(
        identical(BrowserActivityReducer.clearInputRequest(cleared), cleared),
        isTrue,
      );
    });

    test('a navigation to a new page clears the previous title', () {
      var state = _fold([
        (
          payload: <String, dynamic>{
            'name': 'browser_navigate',
            'tool_call_id': 'c1',
            'result': {'url': 'https://example.com/', 'title': 'Example'},
          },
          running: false,
        ),
      ]);
      expect(state.title, 'Example');

      state = BrowserActivityReducer.reduce(
        state,
        BrowserToolEvent.tryParse({
          'name': 'browser_navigate',
          'tool_call_id': 'c2',
          'result': {'url': 'https://other.test/'},
        }, running: false)!,
      );
      expect(state.url, 'https://other.test/');
      expect(state.title, isNull);
    });

    test('a repeated event does not change the state object', () {
      final event = BrowserToolEvent.tryParse({
        'name': 'browser_click',
        'tool_call_id': 'c1',
      }, running: false)!;
      final once = BrowserActivityReducer.reduce(
        BrowserSessionState.empty,
        event,
      );
      expect(
        identical(BrowserActivityReducer.reduce(once, event), once),
        isTrue,
      );
    });
  });
}
