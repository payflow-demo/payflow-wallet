const winston = require('winston');

// Build transports based on environment
const transports = [];

// Always log to console (stdout/stderr) - container-friendly; no colorize in production (ANSI escapes break log aggregators)
const consoleFormat = process.env.NODE_ENV === 'production'
  ? winston.format.simple()
  : winston.format.combine(winston.format.colorize(), winston.format.simple());
transports.push(new winston.transports.Console({ format: consoleFormat }));

// Only use file logging in development (not in containers)
if (process.env.NODE_ENV === 'development' && !process.env.CONTAINER_ENV) {
  transports.push(
    new winston.transports.File({ filename: 'logs/error.log', level: 'error' }),
    new winston.transports.File({ filename: 'logs/combined.log' })
  );
}

const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  defaultMeta: { 
    service: process.env.SERVICE_NAME || 'unknown-service',
    environment: process.env.NODE_ENV || 'development'
  },
  transports
});

// Add correlation ID support
logger.withCorrelation = (correlationId) => {
  return logger.child({ correlationId });
};

module.exports = logger;
