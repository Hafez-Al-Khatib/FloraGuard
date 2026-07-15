import 'package:flutter_test/flutter_test.dart';
import 'package:plant_monitoring_dashboard/models/telemetry.dart';

void main() {
  group('zoneOf', () {
    test('strips known device prefixes to the shared zone key', () {
      expect(zoneOf('camera-zone-a-1'), 'zone-a-1');
      expect(zoneOf('soil-zone-a-1'), 'zone-a-1');
      expect(zoneOf('cam-greenhouse-a'), 'greenhouse-a');
      expect(zoneOf('controller-zone-b'), 'zone-b');
      expect(zoneOf('ctrl-zone-b'), 'zone-b');
    });

    test('a camera and soil node in one zone resolve to the same key', () {
      expect(zoneOf('camera-zone-a-1'), equals(zoneOf('soil-zone-a-1')));
    });

    test('returns null when no device prefix applies', () {
      expect(zoneOf('node-01'), isNull);
      expect(zoneOf('random'), isNull);
      expect(zoneOf('soil-'), isNull); // nothing left after the prefix
    });
  });

  group('linkedPeer', () {
    final cam = TelemetrySnapshot(
        nodeId: 'camera-zone-a-1', detectionIssue: 'Tomato_Late_blight');
    final soil = TelemetrySnapshot(nodeId: 'soil-zone-a-1', moisture: 42);
    final otherSoil = TelemetrySnapshot(nodeId: 'soil-zone-b-1', moisture: 30);

    test('a camera finds the soil node in its zone', () {
      expect(linkedPeer([cam, soil, otherSoil], cam, wantSoil: true)?.nodeId,
          'soil-zone-a-1');
    });

    test('a soil node finds the camera in its zone', () {
      expect(linkedPeer([cam, soil], soil, wantSoil: false)?.nodeId,
          'camera-zone-a-1');
    });

    test('returns null when the zone has no peer of the wanted kind', () {
      expect(linkedPeer([cam, otherSoil], cam, wantSoil: true), isNull);
    });

    test('does not match a different zone', () {
      expect(linkedPeer([cam, otherSoil], cam, wantSoil: true)?.nodeId, isNull);
    });
  });

  group('isOffline', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    test('no readings at all is offline', () {
      // A paired-but-silent node: values expired from the cache.
      expect(TelemetrySnapshot(nodeId: 'soil-zone-a').isOffline, isTrue);
    });

    test('fresh readings are not offline', () {
      final live = TelemetrySnapshot(
          nodeId: 'soil-zone-a', moisture: 42, lastSeen: now);
      expect(live.isOffline, isFalse);
    });

    test('stale contact is offline even with lingering readings', () {
      final stale = TelemetrySnapshot(
          nodeId: 'soil-zone-a', moisture: 42, lastSeen: now - 600);
      expect(stale.isOffline, isTrue);
    });

    test('a live mains node (null battery) is not offline', () {
      // Mains-powered soil node: no battery reading, but moisture is live.
      final mains = TelemetrySnapshot(
          nodeId: 'soil-zone-a', moisture: 30, lastSeen: now);
      expect(mains.isMains, isTrue);
      expect(mains.isOffline, isFalse);
    });
  });
}
