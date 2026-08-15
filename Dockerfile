# syntax=docker/dockerfile:1

FROM node:24-slim AS base

ENV PNPM_HOME=/pnpm
ENV PATH="$PNPM_HOME:$PATH"

RUN corepack enable && pnpm config set store-dir /pnpm/store

WORKDIR /app

# Native dependencies required by better-sqlite3 and other packages.
FROM base AS build-base

RUN apt-get update \
  && apt-get install -y --no-install-recommends g++ make python3 \
  && rm -rf /var/lib/apt/lists/*

# Fetch all workspace dependencies.
FROM build-base AS store

COPY pnpm-lock.yaml pnpm-workspace.yaml ./

RUN pnpm fetch

# Copy workspace manifests and build-generation inputs.
FROM store AS workspace

COPY package.json .npmrc tsconfig.base.json ./

COPY packages/harness/package.json packages/harness/package.json
COPY packages/server/package.json packages/server/package.json
COPY packages/sdk/package.json packages/sdk/package.json
COPY packages/frontend/package.json packages/frontend/package.json
COPY packages/trueforge-ui-sdk/package.json packages/trueforge-ui-sdk/package.json

COPY packages/harness/scripts packages/harness/scripts
COPY packages/harness/src/core/sandbox/scripts packages/harness/src/core/sandbox/scripts

# Build the harness and server.
# Full workspace dependencies are required because TypeScript build types
# such as @types/node and @types/jest are devDependencies.
FROM workspace AS builder

RUN pnpm install --frozen-lockfile --offline

COPY packages/harness packages/harness
COPY packages/server packages/server

RUN pnpm --filter @truefoundry/trueforge-core build \
  && pnpm --filter @truefoundry/trueforge build

# Build the frontend.
FROM workspace AS frontend-builder

RUN pnpm install --frozen-lockfile --offline

COPY packages/sdk packages/sdk

RUN pnpm --filter @truefoundry/trueforge-sdk build

COPY packages/trueforge-ui-sdk packages/trueforge-ui-sdk

RUN pnpm --filter @truefoundry/trueforge-ui build

COPY packages/frontend packages/frontend

RUN pnpm --filter frontend build

# Install production dependencies only.
FROM workspace AS prod-deps

RUN pnpm install \
  --frozen-lockfile \
  --offline \
  --prod \
  --filter @truefoundry/trueforge...

# Minimal production image.
FROM base AS runner

ENV NODE_ENV=production

COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=prod-deps /app/packages/harness/node_modules ./packages/harness/node_modules
COPY --from=prod-deps /app/packages/server/node_modules ./packages/server/node_modules

COPY --from=builder /app/packages/harness/package.json ./packages/harness/package.json
COPY --from=builder /app/packages/harness/dist ./packages/harness/dist

COPY --from=builder /app/packages/server/package.json ./packages/server/package.json
COPY --from=builder /app/packages/server/dist ./packages/server/dist

COPY --from=frontend-builder /app/packages/frontend/dist ./packages/server/dist/_frontend

WORKDIR /app/packages/server

EXPOSE 8790

CMD ["node", "dist/main.js"]
