const client = require('prom-client');

// Create a Registry
const register = new client.Registry();

// Add default metrics (CPU, memory, etc.)
client.collectDefaultMetrics({ register });

// Custom metrics
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.1, 0.5, 1, 2, 5]
});

const httpRequestTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code']
});

// Use getSingleMetric to avoid "already registered" when module is loaded multiple times in same process
const transactionTotal =
  register.getSingleMetric('transactions_total') ||
  new client.Counter({
    name: 'transactions_total',
    help: 'Total number of transactions processed',
    labelNames: ['status', 'type', 'service']
  });

const transactionDuration = new client.Histogram({
  name: 'transaction_duration_seconds',
  help: 'Transaction processing duration',
  labelNames: ['status'],
  buckets: [1, 2, 5, 10, 30]
});

const queueDepth = new client.Gauge({
  name: 'queue_depth',
  help: 'Current depth of message queue',
  labelNames: ['queue_name']
});

const activeConnections = new client.Gauge({
  name: 'active_connections',
  help: 'Number of active connections',
  labelNames: ['service', 'type']
});

const databaseQueryDuration = new client.Histogram({
  name: 'database_query_duration_seconds',
  help: 'Database query duration',
  labelNames: ['query_type'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2]
});

const cacheHitRate = new client.Counter({
  name: 'cache_hits_total',
  help: 'Total cache hits',
  labelNames: ['cache_type', 'hit']
});

// ============================================
// CRITICAL BUSINESS METRICS
// ============================================
// These metrics would have caught the CronJob/transaction issues

const pendingTransactionsGauge = new client.Gauge({
  name: 'payflow_pending_transactions_total',
  help: 'Number of transactions currently in PENDING status'
});

const oldestPendingTransactionGauge = new client.Gauge({
  name: 'payflow_transactions_oldest_pending_timestamp',
  help: 'Unix timestamp of oldest pending transaction'
});

const pendingTransactionAmountGauge = new client.Gauge({
  name: 'payflow_pending_transaction_amount_total',
  help: 'Total amount (dollars) stuck in pending transactions'
});

const transactionsByStatus = new client.Gauge({
  name: 'payflow_transactions_by_status',
  help: 'Current transaction count by status',
  labelNames: ['status']  // PENDING, COMPLETED, FAILED
});

// ============================================
// DATABASE METRICS
// ============================================

const dbConnectionPoolSize = new client.Gauge({
  name: 'payflow_db_connection_pool_size',
  help: 'Current database connection pool size',
  labelNames: ['state']  // idle, active, waiting, total
});

const dbQueryErrors = new client.Counter({
  name: 'payflow_db_query_errors_total',
  help: 'Total database query errors',
  labelNames: ['error_type', 'service']  // timeout, connection, syntax, deadlock
});

const dbConnectionErrors = new client.Counter({
  name: 'payflow_db_connection_errors_total',
  help: 'Failed database connection attempts',
  labelNames: ['reason', 'service']
});

// ============================================
// RABBITMQ METRICS
// ============================================

const rabbitmqMessageAge = new client.Histogram({
  name: 'payflow_rabbitmq_message_age_seconds',
  help: 'Age of messages in queue',
  labelNames: ['queue'],
  buckets: [1, 5, 10, 30, 60, 120, 300]
});

const rabbitmqPublishErrors = new client.Counter({
  name: 'payflow_rabbitmq_publish_errors_total',
  help: 'Failed message publishes',
  labelNames: ['queue', 'reason', 'service']
});

const rabbitmqConsumeErrors = new client.Counter({
  name: 'payflow_rabbitmq_consume_errors_total',
  help: 'Failed message consumption',
  labelNames: ['queue', 'reason', 'service']
});

// ============================================
// CIRCUIT BREAKER METRICS
// ============================================

const circuitBreakerState = new client.Gauge({
  name: 'payflow_circuit_breaker_state',
  help: 'Circuit breaker state (0=closed, 1=open, 0.5=half-open)',
  labelNames: ['service', 'state']
});

const circuitBreakerTransitions = new client.Counter({
  name: 'payflow_circuit_breaker_transitions_total',
  help: 'Circuit breaker state transitions',
  labelNames: ['service', 'from_state', 'to_state']
});

// ============================================
// CRONJOB METRICS (For timeout handler)
// ============================================

const cronJobExecutions = new client.Counter({
  name: 'payflow_cronjob_executions_total',
  help: 'Total CronJob executions',
  labelNames: ['job_name', 'status']  // success, failure
});

const cronJobDuration = new client.Histogram({
  name: 'payflow_cronjob_duration_seconds',
  help: 'CronJob execution duration',
  labelNames: ['job_name'],
  buckets: [1, 5, 10, 30, 60, 120]
});

const transactionsReversedByCron = new client.Counter({
  name: 'payflow_transactions_reversed_by_cronjob_total',
  help: 'Transactions automatically reversed by timeout handler',
  labelNames: ['reason']  // timeout, error, manual
});

// ============================================
// SLI/SLO METRICS
// ============================================

const sloErrorBudget = new client.Gauge({
  name: 'payflow_slo_error_budget_remaining',
  help: 'Remaining error budget for SLO (99.9% uptime)',
  labelNames: ['period']  // day, week, month
});

const sloLatency = new client.Histogram({
  name: 'payflow_slo_latency_seconds',
  help: 'Request latency for SLO tracking',
  labelNames: ['endpoint', 'method'],
  buckets: [0.05, 0.1, 0.2, 0.5, 1, 2, 5]
});

// ============================================
// BUSINESS KPIs
// ============================================

const dailyActiveUsers = new client.Gauge({
  name: 'payflow_daily_active_users',
  help: 'Number of unique users with activity today'
});

const transactionVolume = new client.Counter({
  name: 'payflow_transaction_volume_dollars_total',
  help: 'Total transaction volume in dollars',
  labelNames: ['status']  // COMPLETED, FAILED
});

const averageTransactionSize = new client.Gauge({
  name: 'payflow_average_transaction_size_dollars',
  help: 'Average transaction amount in dollars',
  labelNames: ['time_window']  // hour, day
});

// Register all metrics (skip transactionTotal if already registered, e.g. double load of this module)
register.registerMetric(httpRequestDuration);
register.registerMetric(httpRequestTotal);
if (!register.getSingleMetric('transactions_total')) register.registerMetric(transactionTotal);
register.registerMetric(transactionDuration);
register.registerMetric(queueDepth);
register.registerMetric(activeConnections);
register.registerMetric(databaseQueryDuration);
register.registerMetric(cacheHitRate);

// Register business metrics
register.registerMetric(pendingTransactionsGauge);
register.registerMetric(oldestPendingTransactionGauge);
register.registerMetric(pendingTransactionAmountGauge);
register.registerMetric(transactionsByStatus);

// Register database metrics
register.registerMetric(dbConnectionPoolSize);
register.registerMetric(dbQueryErrors);
register.registerMetric(dbConnectionErrors);

// Register RabbitMQ metrics
register.registerMetric(rabbitmqMessageAge);
register.registerMetric(rabbitmqPublishErrors);
register.registerMetric(rabbitmqConsumeErrors);

// Register circuit breaker metrics
register.registerMetric(circuitBreakerState);
register.registerMetric(circuitBreakerTransitions);

// Register CronJob metrics
register.registerMetric(cronJobExecutions);
register.registerMetric(cronJobDuration);
register.registerMetric(transactionsReversedByCron);

// Register SLO metrics
register.registerMetric(sloErrorBudget);
register.registerMetric(sloLatency);

// Register KPI metrics
register.registerMetric(dailyActiveUsers);
register.registerMetric(transactionVolume);
register.registerMetric(averageTransactionSize);

// Middleware for HTTP metrics
function metricsMiddleware(req, res, next) {
  const start = Date.now();

  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    const route = req.route?.path || req.path;

    httpRequestDuration
      .labels(req.method, route, res.statusCode)
      .observe(duration);

    httpRequestTotal
      .labels(req.method, route, res.statusCode)
      .inc();
  });

  next();
}

// Metrics endpoint handler
async function metricsHandler(req, res) {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
}

module.exports = {
  // Core
  register,
  metricsMiddleware,
  metricsHandler,
  
  // HTTP Metrics
  httpRequestDuration,
  httpRequestTotal,
  
  // Transaction Metrics
  transactionTotal,
  transactionDuration,
  
  // Infrastructure
  queueDepth,
  activeConnections,
  databaseQueryDuration,
  cacheHitRate,
  
  // Business Metrics
  pendingTransactionsGauge,
  oldestPendingTransactionGauge,
  pendingTransactionAmountGauge,
  transactionsByStatus,
  
  // Database Metrics
  dbConnectionPoolSize,
  dbQueryErrors,
  dbConnectionErrors,
  
  // RabbitMQ Metrics
  rabbitmqMessageAge,
  rabbitmqPublishErrors,
  rabbitmqConsumeErrors,
  
  // Circuit Breaker
  circuitBreakerState,
  circuitBreakerTransitions,
  
  // CronJob Metrics
  cronJobExecutions,
  cronJobDuration,
  transactionsReversedByCron,
  
  // SLO Metrics
  sloErrorBudget,
  sloLatency,
  
  // KPI Metrics
  dailyActiveUsers,
  transactionVolume,
  averageTransactionSize
};
