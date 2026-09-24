import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapx/logic/floor_graph.dart';
import 'package:mapx/models/floor_map_data.dart';
import 'package:mapx/models/map_models.dart';
import 'package:mapx/screens/map_editor_screen.dart';
import 'package:mapx/widgets/path_map_painter.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = 'map_Test#0';

/// A 10m walk east with a place at each end.
Map<String, dynamic> _map() {
  final segment = PathSegment();
  for (var i = 0; i < 10; i++) {
    segment.steps.add(RawStep(90, 1));
  }
  return {
    'name': 'Test',
    'floor': 0,
    'stepCount': 10,
    'segments': [segment.toJson()],
    'waypoints': [Waypoint(0, 'Door').toJson(), Waypoint(10, 'Lab').toJson()],
  };
}

void main() {
  testWidgets('adds a place by tapping the path, then saves it', (tester) async {
    SharedPreferences.setMockInitialValues({_key: jsonEncode(_map())});
    await tester.pumpWidget(const MaterialApp(home: MapEditorScreen(mapKey: _key, title: 'Test · Floor 0')));
    await tester.pumpAndSettle();

    // Tap the node 4m along the walk, located the same way the editor does.
    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PathMapPainter);
    final box = tester.getRect(canvas);
    final graph = FloorGraph.build([PathSegment.fromJson(_map()['segments'][0])], 0);
    final viewport = MapViewport.fit(graph.nodes, const [], box.size);
    await tester.tapAt(box.topLeft + viewport.toScreen(graph.nodes[4].east, graph.nodes[4].north));
    await tester.pumpAndSettle();

    expect(find.text('Add Marker'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Printer');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final saved = FloorMapData.fromJson(_key, jsonDecode(prefs.getString(_key)!) as Map);
    final printer = saved.waypoints.firstWhere((w) => w.label == 'Printer');
    expect(printer.globalStepIndex, 4);
  });

  testWidgets('draws a path between two places and stores it', (tester) async {
    SharedPreferences.setMockInitialValues({_key: jsonEncode(_map())});
    await tester.pumpWidget(const MaterialApp(home: MapEditorScreen(mapKey: _key, title: 'Test · Floor 0')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Paths'));
    await tester.pumpAndSettle();

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PathMapPainter);
    final box = tester.getRect(canvas);
    final graph = FloorGraph.build([PathSegment.fromJson(_map()['segments'][0])], 0);
    final viewport = MapViewport.fit(graph.nodes, const [], box.size);
    Offset at(double e, double n) => box.topLeft + viewport.toScreen(e, n);

    await tester.tapAt(at(0, 0)); // Door
    await tester.pumpAndSettle();
    expect(find.text('From Door'), findsOneWidget);
    await tester.tapAt(at(5, 1)); // a bend off the walk
    await tester.pumpAndSettle();
    expect(find.textContaining('1 bend'), findsOneWidget);
    await tester.tapAt(at(10, 0)); // Lab
    await tester.pumpAndSettle();
    expect(find.textContaining('Path added'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    final saved = FloorMapData.fromJson(_key, jsonDecode(prefs.getString(_key)!) as Map);
    expect(saved.links, hasLength(1));
    expect((saved.links.single.fromNode, saved.links.single.toNode), (0, 10));
    expect(saved.links.single.bends.single.$1, closeTo(5, 0.1));
    expect(saved.links.single.bends.single.$2, closeTo(1, 0.1));
  });
}
