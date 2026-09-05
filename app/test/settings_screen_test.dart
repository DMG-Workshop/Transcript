import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/settings/provider_config.dart';
import 'package:transcript_app/src/settings/secure_key_store.dart';
import 'package:transcript_app/src/settings/settings_screen.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  // The screen is two full provider sections tall. The default 800x600 test viewport
  // leaves the second one unbuilt, so these tests run on a surface that fits both.
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .implicitView!;
    view.physicalSize = const Size(1200, 2600);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .implicitView!;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<InMemoryKeyStore> pumpSettings(
    WidgetTester tester,
    List<Object> replies, {
    InMemoryKeyStore? keys,
  }) async {
    final store = keys ?? InMemoryKeyStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transportProvider.overrideWithValue(RecordingTransport(replies)),
          keyStoreProvider.overrideWithValue(store),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('the two stages are offered separately', (tester) async {
    await pumpSettings(tester, []);

    expect(find.text('SPEECH TO TEXT'), findsOneWidget);
    expect(find.text('NOTES AND TASKS'), findsOneWidget);
  });

  testWidgets('Claude is offered for notes but never for transcription',
      (tester) async {
    await pumpSettings(tester, []);

    // The whole architecture in one assertion: the Messages API takes no audio, so
    // Claude must not appear as something the user can transcribe with.
    expect(
      ProviderKind.forStage(ProviderStage.transcription),
      isNot(contains(ProviderKind.anthropic)),
    );
    expect(
      ProviderKind.forStage(ProviderStage.structuring),
      contains(ProviderKind.anthropic),
    );
    expect(find.text('Claude'), findsOneWidget);
  });

  testWidgets('the default transcription option needs no key at all', (tester) async {
    await pumpSettings(tester, []);

    expect(ProviderKind.forStage(ProviderStage.transcription).first.needsKey, isFalse);
    expect(find.textContaining('Free, offline, no key'), findsOneWidget);
  });

  testWidgets('testing without a key says so instead of calling out', (tester) async {
    final transport = RecordingTransport(const []);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transportProvider.overrideWithValue(transport),
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Structuring defaults to Claude, which needs a key none has been entered for.
    await tester.tap(find.text('Test connection').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('No API key saved'), findsOneWidget);
    expect(transport.calls, isEmpty,
        reason: 'no point spending a request to discover there is no key');
  });

  testWidgets('a successful test reports the models the key can reach',
      (tester) async {
    final store = InMemoryKeyStore();
    await store.write('anthropic', 'sk-test-key');

    await pumpSettings(
      tester,
      [
        HttpReply(
          200,
          jsonEncode({
            'data': [
              {'id': 'claude-opus-5'},
              {'id': 'claude-sonnet-5'},
            ],
          }),
        ),
      ],
      keys: store,
    );

    await tester.tap(find.text('Test connection').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Connected'), findsOneWidget);
    expect(find.textContaining('claude-sonnet-5'), findsOneWidget);
  });

  testWidgets('a rejected key gets an explanation and a remedy', (tester) async {
    final store = InMemoryKeyStore();
    await store.write('anthropic', 'sk-wrong');

    await pumpSettings(
      tester,
      [
        HttpReply(401, jsonEncode({
          'error': {'message': 'invalid x-api-key'},
        })),
      ],
      keys: store,
    );

    await tester.tap(find.text('Test connection').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('rejected the credentials'), findsOneWidget);
    expect(find.textContaining('invalid x-api-key'), findsOneWidget);
    expect(find.textContaining('revoked'), findsOneWidget);
  });

  testWidgets('a local endpoint gets an address field, not a key field',
      (tester) async {
    await pumpSettings(tester, []);

    await tester.tap(find.text('Ollama'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Address'), findsOneWidget);
    expect(find.textContaining('192.168'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'API key'), findsNothing);
  });

  testWidgets('an unreachable local server explains the usual causes',
      (tester) async {
    await pumpSettings(tester, [
      const TransportException(TransportFailure.refused, 'Connection refused'),
    ]);

    await tester.tap(find.text('Ollama'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Address'), 'http://192.168.1.50:11434');
    await tester.tap(find.text('Test connection').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing is listening'), findsOneWidget);
    expect(find.textContaining('OLLAMA_HOST'), findsOneWidget);
    expect(find.textContaining('Local Network'), findsOneWidget,
        reason: 'on iOS a blocked request looks identical to a dead server');
  });

  testWidgets('entering a key stores it and clears the field', (tester) async {
    final store = InMemoryKeyStore();

    await pumpSettings(
      tester,
      [HttpReply(200, jsonEncode({'data': <Object>[]}))],
      keys: store,
    );

    await tester.enterText(
        find.widgetWithText(TextField, 'API key'), 'sk-brand-new');
    await tester.tap(find.text('Test connection').last);
    await tester.pumpAndSettle();

    expect(await store.read('anthropic'), 'sk-brand-new');
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller?.text, isEmpty,
        reason: 'the key is never left sitting in a visible field');
  });

  test('a stored key is masked rather than displayed', () {
    expect(SecureKeyStore.mask('sk-ant-api03-abcdefghijklmnop'), 'sk-••••••••mnop');
    expect(SecureKeyStore.mask('short'), '•••••');
  });
}
