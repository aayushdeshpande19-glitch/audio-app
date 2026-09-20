import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localbeat/database.dart';
import 'package:localbeat/main.dart';
import 'package:localbeat/models.dart';

void main() {
  testWidgets('empty state is readable and accessible at large text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: appTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 720),
              textScaler: TextScaler.linear(1.5),
            ),
            child: const Scaffold(
              body: EmptyLibrary(
                title: 'Keep your favorites close',
                body: 'Tap the heart on a song to save it here.',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Keep your favorites close'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty state with import button renders without overflow', (tester) async {
    final db = LibraryDatabase(NativeDatabase.memory());
    addTearDown(() => db.close());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
        ],
        child: MaterialApp(
          theme: appTheme(),
          home: const Scaffold(
            body: EmptyLibrary(
              title: 'Make yourself at home',
              body: 'Choose a folder. We’ll take care of the music.',
              import: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Choose music folder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('missing artwork falls back to a music icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: const Scaffold(body: Cover()),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
  });
  test('time label preserves minutes for long tracks', () {
    expect(timeLabel(3661000), '61:01');
    expect(timeLabel(0), '0:00');
  });
}
