"""Publish simulated soil-node telemetry to the local MQTT broker.

Exercises the full MQTT -> API subscriber -> Redis -> dashboard path without
any hardware. Handy for demoing the live dashboard: run with --loop and watch
the card update on http://localhost:8080.

Usage (from edge-server/, via the venv python):
    python pub_telemetry.py                      # one reading for soil-zone-a
    python pub_telemetry.py soil-zone-b 47.2     # specific node + moisture
    python pub_telemetry.py soil-zone-a --loop   # stream changing values, Ctrl+C to stop

Talks to localhost:1883 (the dev broker's published port).
"""
from __future__ import annotations

import json
import random
import sys
import time

import paho.mqtt.client as mqtt

HOST, PORT = "localhost", 1883


def make_payload(node_id: str, moisture: float, hello: bool = False) -> dict:
    if hello:
        return {
            "node_id": node_id, "hello": True, "kind": "soil",
            "reset_reason": "poweron", "free_heap": 218000,
        }
    return {
        "node_id": node_id,
        "sensor_ok": True,
        "moisture": round(moisture, 1),
        "battery_pct": 92,
        "reset_reason": "deepsleep",
        "free_heap": random.randint(200000, 220000),
    }


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    loop = "--loop" in sys.argv

    node_id = args[0] if args else "soil-zone-a"
    moisture = float(args[1]) if len(args) > 1 else 58.4

    client = mqtt.Client(client_id="pms-sim-publisher", clean_session=True)
    client.connect(HOST, PORT, keepalive=30)
    client.loop_start()

    topic = f"pms/telemetry/{node_id}"

    # Announce the node first so its card appears immediately.
    client.publish(topic, json.dumps(make_payload(node_id, moisture, hello=True)))
    print(f"hello  -> {topic}")
    time.sleep(0.3)

    if not loop:
        payload = make_payload(node_id, moisture)
        client.publish(topic, json.dumps(payload))
        print(f"reading-> {topic}  {payload}")
        time.sleep(0.5)
    else:
        print("Streaming (Ctrl+C to stop)...")
        m = moisture
        try:
            while True:
                m = max(5.0, min(95.0, m + random.uniform(-4, 4)))
                payload = make_payload(node_id, m)
                client.publish(topic, json.dumps(payload))
                print(f"reading-> {topic}  moisture={payload['moisture']}")
                time.sleep(3)
        except KeyboardInterrupt:
            print("\nstopped.")

    client.loop_stop()
    client.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
