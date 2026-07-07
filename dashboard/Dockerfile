# Stage 1: Build Flutter web
FROM ghcr.io/cirruslabs/flutter:stable AS builder

WORKDIR /app

# Copy dependency manifests first for layer caching
COPY pubspec.yaml pubspec.lock* ./
RUN flutter pub get

# Build.
# --pwa-strategy=none disables the service worker. Flutter's default SW caches
# the whole app aggressively, so after a rebuild users keep seeing the old app
# until they manually clear storage. For a LAN dashboard that's pure friction;
# fresh-on-reload is what we want.
COPY . .
RUN flutter build web --no-tree-shake-icons --release --pwa-strategy=none

# Stage 2: Serve with nginx (minimal alpine image)
FROM nginx:alpine

COPY --from=builder /app/build/web /usr/share/nginx/html
COPY docker.nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
