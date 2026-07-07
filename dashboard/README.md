# Plant Monitoring Dashboard

Flutter web dashboard for the Plant Monitoring System edge server.

## Build for deployment

The Pi uses a lightweight nginx image that serves the pre-built web bundle,
because the Cirrus Labs Flutter Docker image is AMD64-only.

```bash
cd dashboard
flutter build web --no-tree-shake-icons --release --pwa-strategy=none
```

`build/web/` is tracked in git (see `.gitignore` exception) so the Pi can deploy
it directly after cloning.

## Development

```bash
flutter run -d chrome
```

Point the dashboard at `https://<pi-ip>/` and enter the API token from
`edge-server/.env` when prompted.
