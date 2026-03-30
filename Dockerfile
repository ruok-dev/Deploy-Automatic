# =============================================================================
# Dockerfile — Multi-stage build otimizado para produção
# =============================================================================

# ─── Stage 1: Dependências ───────────────────────────────────────────────────
FROM node:20-alpine AS deps

WORKDIR /app

# Copia apenas o necessário para instalar deps (melhor uso de cache)
COPY package.json package-lock.json ./

RUN npm ci --omit=dev --ignore-scripts


# ─── Stage 2: Build ──────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

COPY . .
RUN npm run build


# ─── Stage 3: Imagem final (produção) ────────────────────────────────────────
FROM node:20-alpine AS production

# Metadados OCI
LABEL org.opencontainers.image.title="My App"
LABEL org.opencontainers.image.description="Production image"
LABEL org.opencontainers.image.source="https://github.com/$GITHUB_REPOSITORY"

# Usuário não-root por segurança
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copia dependências de produção e build
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=builder /app/dist       ./dist
COPY --from=builder /app/package.json .

# Permissões corretas
RUN chown -R appuser:appgroup /app

USER appuser

ENV NODE_ENV=production \
    PORT=3000

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "dist/server.js"]
