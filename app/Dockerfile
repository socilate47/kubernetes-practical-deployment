# Biashara OS v0.2.0 image. Node.js 24 + @aws-sdk/client-s3 for the invoice
# upload path. Matches the recorded design in docs/deployment-journey.pdf §12.
FROM node:24-slim AS base
WORKDIR /app

# Install only production dependencies first so the layer caches across code
# changes. The PDF notes that the original Dockerfile forgot `npm ci` and the
# resulting image was missing @aws-sdk/client-s3 at runtime — this fixes it.
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

# Application source. After the frontend/backend split the entrypoint is
# backend/server.js; the SPA lives in frontend/ and is served statically from
# backend/server.js at `/`.
COPY . .

# SQLite data directory. The Kubernetes PVC mounts over this at runtime
# (/app/data/biashara.sqlite is the live file). Making the dir in-image keeps
# a vanilla `podman run` working too.
RUN mkdir -p /app/data && chown -R 1000:1000 /app/data
VOLUME ["/app/data"]

ENV NODE_ENV=production \
    PORT=3000
EXPOSE 3000

USER 1000:1000
CMD ["node", "backend/server.js"]
