import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plant_monitoring_dashboard/models/telemetry.dart';
import 'package:plant_monitoring_dashboard/widgets/telemetry_card.dart';

void main() {
  testWidgets('TelemetryCard invokes onTap when tapped (soil card)',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              child: TelemetryCard(
                snapshot: TelemetrySnapshot(nodeId: 'soil-zone-a', moisture: 42),
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      ),
    );
    // Let the entrance animation complete so the card is fully laid in.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(TelemetryCard));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('TelemetryCard with a null-data placeholder is still tappable',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              child: TelemetryCard(
                // No readings → placeholder body (the current dev-stack state).
                snapshot: TelemetrySnapshot(nodeId: 'soil-zone-a'),
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(TelemetryCard));
    await tester.pump();
    expect(taps, 1);
  });
}
