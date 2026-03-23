# ============================================
# PayFlow Auth Service - Optimized Multi-Stage Build
# Target: <100MB
# ============================================
# Build from repo root or services/: docker build -f auth-service/Dockerfile .
# (Context must include shared/ and auth-service/.)

FROM node:22-alpine AS deps
WORKDIR /app

COPY auth-service/package*.json ./
RUN npm ci --only=production --ignore-scripts && \
    npm cache clean --force

FROM node:22-alpine AS production

WORKDIR /app

RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

COPY --from=deps --chown=nodejs:nodejs /app/node_modules ./node_modules
COPY --chown=nodejs:nodejs shared ./shared
COPY --chown=nodejs:nodejs auth-service .

USER nodejs

EXPOSE 3004

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3004/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"

CMD ["node", "server.js"]
