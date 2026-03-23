# ============================================
# PayFlow Transaction Service - Optimized Multi-Stage Build
# Target: <100MB (reduced from 200MB)
# ============================================

FROM node:22-alpine AS deps
WORKDIR /app

COPY transaction-service/package*.json ./
RUN npm ci --only=production --ignore-scripts && \
    npm cache clean --force

FROM node:22-alpine AS production

WORKDIR /app

RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001

COPY --from=deps --chown=nodejs:nodejs /app/node_modules ./node_modules

# Copy shared dependencies (at /shared so require('../shared/...') from /app resolves)
COPY --chown=nodejs:nodejs shared ./shared

# Copy application code
COPY --chown=nodejs:nodejs transaction-service .

USER nodejs

EXPOSE 3002

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3002/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"

CMD ["node", "server.js"]
