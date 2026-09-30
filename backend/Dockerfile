FROM node:24-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /tmp/ytdlp \
    && curl -fL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /tmp/ytdlp/yt-dlp \
    && curl -fL https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS -o /tmp/ytdlp/SHA2-256SUMS \
    && cd /tmp/ytdlp \
    && grep -E '^[0-9a-fA-F]{64}[[:space:]]+\*?yt-dlp$' SHA2-256SUMS | sed 's/\*/ /' | sha256sum -c - \
    && install -m 0755 yt-dlp /usr/local/bin/yt-dlp \
    && rm -rf /tmp/ytdlp

WORKDIR /app
COPY package.json ./
COPY src ./src

RUN mkdir -p /app/cache && chown -R node:node /app
USER node

ENV BIND_HOST=0.0.0.0 \
    PORT=8787 \
    ALLOW_LAN=true \
    YTDLP_PATH=/usr/local/bin/yt-dlp \
    CACHE_DIR=/app/cache

EXPOSE 8787
CMD ["node", "./src/index.js"]
