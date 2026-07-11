#!/usr/bin/env python3
"""Visual InfluxDB telemetry inspector — run on the Pi."""
import os
import sys
from pathlib import Path
from datetime import datetime, timedelta, timezone
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from influxdb_client import InfluxDBClient
from influxdb_client.client.query_api import QueryOptions


def load_env():
    """Read .env from the script's directory or parent."""
    env_file = Path(__file__).with_name(".env")
    if not env_file.exists():
        env_file = Path(__file__).parent / ".env"
    if not env_file.exists():
        env_file = Path(__file__).parent.parent / ".env"
    settings = {}
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                settings[k] = v
    return settings


def query_telemetry(client, bucket, org, node_id=None, hours=24):
    """Return [(time, field, value), ...] for the given range."""
    start = f"-{int(hours)}h"
    node_filter = f'|> filter(fn: (r) => r.node_id == "{node_id}")' if node_id else ""
    flux = (
        f'from(bucket: "{bucket}")'
        f' |> range(start: {start})'
        f' |> filter(fn: (r) => r._measurement == "telemetry")'
        f' {node_filter}'
        f' |> filter(fn: (r) => r._field == "moisture" or r._field == "temperature" or r._field == "battery_pct" or r._field == "ec")'
        f' |> aggregateWindow(every: 1m, fn: mean, createEmpty: false)'
        f' |> yield(name: "mean")'
    )
    tables = client.query_api().query(flux, org=org)
    rows = []
    for table in tables:
        for record in table.records:
            t = record.get_time()
            if t is None:
                continue
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
            rows.append((t, record.get_field(), float(record.get_value())))
    return sorted(rows)


def build_table(rows, hours=24):
    """Build a text table of the latest reading per node per field."""
    if not rows:
        return "No telemetry data in InfluxDB for the last {} hours.".format(hours)
    # Group by node, then field, keep latest
    latest = defaultdict(dict)
    for t, field, value in rows:
        # node_id is lost in the simplified query — let me rewrite to include it
        pass
    return "Re-querying with node_id..."


def query_with_node_id(client, bucket, org, hours=24):
    """Return dict: {node_id: {field: [(time, value), ...]}}."""
    start = f"-{int(hours)}h"
    flux = (
        f'from(bucket: "{bucket}")'
        f' |> range(start: {start})'
        f' |> filter(fn: (r) => r._measurement == "telemetry")'
        f' |> filter(fn: (r) => r._field == "moisture" or r._field == "temperature" or r._field == "battery_pct" or r._field == "ec")'
        f' |> aggregateWindow(every: 5m, fn: mean, createEmpty: false)'
    )
    tables = client.query_api().query(flux, org=org)
    data = defaultdict(lambda: defaultdict(list))
    for table in tables:
        for record in table.records:
            t = record.get_time()
            if t is None:
                continue
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
            node_id = record.values.get("node_id", "unknown")
            field = record.get_field()
            data[node_id][field].append((t, float(record.get_value())))
    return data


def plot_telemetry(data, output_path, hours=24):
    """Generate a multi-panel chart."""
    nodes = list(data.keys())
    if not nodes:
        print("No data to plot.")
        return

    fields = set()
    for node_fields in data.values():
        fields.update(node_fields.keys())
    fields = sorted(fields)

    n_nodes = len(nodes)
    n_fields = len(fields)
    fig, axes = plt.subplots(n_nodes, n_fields, figsize=(4 * n_fields, 3 * n_nodes), squeeze=False)

    colors = plt.cm.tab10.colors
    for i, node_id in enumerate(nodes):
        for j, field in enumerate(fields):
            ax = axes[i][j]
            pts = data[node_id].get(field, [])
            if pts:
                times, values = zip(*pts)
                ax.plot(times, values, "-o", color=colors[j % len(colors)], markersize=2)
                ax.set_title(f"{node_id} — {field}")
                ax.set_ylabel(field)
                ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
                ax.xaxis.set_major_locator(mdates.HourLocator(interval=max(1, hours // 6)))
                plt.setp(ax.xaxis.get_majorticklabels(), rotation=45, ha="right")
                ax.grid(True, alpha=0.3)
            else:
                ax.set_title(f"{node_id} — {field} (no data)")
                ax.set_visible(False)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    print(f"Chart saved: {output_path}")


def print_table(data, hours=24):
    """Print a summary table of latest values per node."""
    print(f"\n{'='*60}")
    print(f"InfluxDB Telemetry Summary (last {hours}h)")
    print(f"{'='*60}")
    for node_id in sorted(data.keys()):
        print(f"\nNode: {node_id}")
        print("-" * 40)
        for field in sorted(data[node_id].keys()):
            pts = data[node_id][field]
            if pts:
                latest_t, latest_v = pts[-1]
                print(f"  {field:12s}: {latest_v:>8.2f}  @ {latest_t.strftime('%Y-%m-%d %H:%M:%S UTC')}")
            else:
                print(f"  {field:12s}: (no data)")
    print(f"\n{'='*60}\n")


def main():
    env = load_env()
    url = env.get("INFLUXDB_URL", "http://localhost:8086")
    token = env.get("INFLUXDB_TOKEN", "")
    org = env.get("INFLUXDB_ORG", "plantmonitor")
    bucket = env.get("INFLUXDB_BUCKET", "telemetry")

    if not token:
        print("ERROR: INFLUXDB_TOKEN not found in .env")
        sys.exit(1)

    hours = int(sys.argv[1]) if len(sys.argv) > 1 else 24

    with InfluxDBClient(url=url, token=token, org=org) as client:
        data = query_with_node_id(client, bucket, org, hours=hours)
        print_table(data, hours=hours)

        output = Path(__file__).with_suffix(".png")
        plot_telemetry(data, output, hours=hours)


if __name__ == "__main__":
    main()
