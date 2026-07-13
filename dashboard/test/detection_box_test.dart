import 'package:flutter_test/flutter_test.dart';
import 'package:plant_monitoring_dashboard/models/telemetry.dart';

void main() {
  test('DetectionBox parses a normalized box and its fields', () {
    final b = DetectionBox.fromJson({
      'box': [0.5, 0.4, 0.2, 0.3],
      'group': 'blight',
      'fine': 'Tomato_Late_blight',
      'confidence': 0.8,
    });
    expect(b.box, [0.5, 0.4, 0.2, 0.3]);
    expect(b.group, 'blight');
    expect(b.fine, 'Tomato_Late_blight');
    expect(b.healthy, isFalse);
    expect(b.confidence, 0.8);
  });

  test('listFrom builds a list, tolerates a null box, and rejects non-lists', () {
    final list = DetectionBox.listFrom([
      {'box': null, 'group': 'healthy', 'confidence': 1.0},
      {'box': [0.5, 0.5, 0.1, 0.1], 'group': 'viral', 'confidence': 0.7},
    ]);
    expect(list.length, 2);
    expect(list.first.box, isNull);
    expect(list.first.healthy, isTrue);
    expect(DetectionBox.listFrom(null), isEmpty);
    expect(DetectionBox.listFrom('nope'), isEmpty);
  });

  test('snapshot parses detections nested under the telemetry detection object', () {
    final s = TelemetrySnapshot.fromJson({
      'node_id': 'cam-zone-a',
      'detection': {
        'issue': 'Blight',
        'confidence': 0.8,
        'detections': [
          {'box': [0.5, 0.5, 0.1, 0.1], 'group': 'blight',
           'fine': 'Tomato_Late_blight', 'confidence': 0.8},
        ],
      },
    });
    expect(s.detections.length, 1);
    expect(s.detections.first.group, 'blight');
    expect(s.detections.first.box, [0.5, 0.5, 0.1, 0.1]);
  });
}
