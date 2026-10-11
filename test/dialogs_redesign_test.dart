import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/widgets/dialogs/add_floor_dialog.dart';
import 'package:mapx/widgets/dialogs/create_building_dialog.dart';
import 'package:mapx/widgets/dialogs/delete_path_dialog.dart';
import 'package:mapx/widgets/dialogs/discard_changes_dialog.dart';
import 'package:mapx/widgets/dialogs/join_path_dialog.dart';
import 'package:mapx/widgets/marker_dialog.dart';

void main() {
  group('CreateBuildingDialog', () {
    testWidgets('renders inputs, handles quick select and validation',
        (tester) async {
      ({String name, int floor})? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await CreateBuildingDialog.show(
                      context,
                      exists: (name, floor) => name == 'Tower A' && floor == 1,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Walk & Record Floor'), findsOneWidget);
      expect(find.text('BUILDING NAME'), findsOneWidget);
      expect(find.text('FLOOR LEVEL'), findsOneWidget);

      // Submit without input triggers validation
      await tester.tap(find.text('Start Recording'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a building name'), findsOneWidget);

      // Enter building name
      await tester.enterText(find.byType(TextField).first, 'Tower A');
      // Tap quick floor chip 'G (0)'
      await tester.tap(find.text('G (0)'));
      await tester.pumpAndSettle();

      // Submit valid input
      await tester.tap(find.text('Start Recording'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.name, 'Tower A');
      expect(result!.floor, 0);
    });
  });

  group('AddFloorDialog', () {
    testWidgets('renders building badge and submits valid floor',
        (tester) async {
      ({String name, int floor})? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await AddFloorDialog.show(
                      context,
                      building: 'Science Hall',
                      exists: (name, floor) => floor == 0,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Add Floor'), findsOneWidget);
      expect(find.text('Science Hall'), findsOneWidget);

      // Quick select F1
      await tester.tap(find.text('F1'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start Recording'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.name, 'Science Hall');
      expect(result!.floor, 1);
    });
  });

  group('JoinPathDialog', () {
    testWidgets('renders distance gap and returns confirmation',
        (tester) async {
      bool? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await JoinPathDialog.show(
                      context,
                      distanceMeters: 2.4,
                      targetName: 'North Exit',
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Join New Path?'), findsOneWidget);
      expect(find.text('Target: North Exit'), findsOneWidget);
      expect(find.textContaining('2.4 m'), findsOneWidget);

      await tester.tap(find.text('Join Path'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });
  });

  group('DeletePathDialog', () {
    testWidgets('renders length and warnings', (tester) async {
      bool? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await DeletePathDialog.show(
                      context,
                      lengthMeters: 14.5,
                      placesCount: 2,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Delete Path?'), findsOneWidget);
      expect(find.textContaining('14.5 m'), findsOneWidget);
      expect(find.textContaining('2 places marked'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });
  });

  group('DiscardChangesDialog', () {
    testWidgets('renders discard options', (tester) async {
      bool? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await DiscardChangesDialog.show(context);
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });
  });

  group('MarkerDialog category selector', () {
    testWidgets('allows selecting stairs and lifts', (tester) async {
      MarkerDialogResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await showDialog<MarkerDialogResult>(
                      context: context,
                      builder: (_) => const MarkerDialog(
                        knownConnectors: [],
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Add Marker'), findsOneWidget);
      expect(find.text('Stairs'), findsOneWidget);
      expect(find.text('Lift'), findsOneWidget);

      await tester.tap(find.text('Stairs'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'West Stairs');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.label, 'West Stairs');
      expect(result!.category, Waypoint.stairsCategory);
    });
  });
}
