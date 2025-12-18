import rateLimit from "express-rate-limit";

export function makeRateLimiter() {
  const windowMs = Number(process.env.RATE_LIMIT_WINDOW_MS || 60_000);
  const max = Number(process.env.RATE_LIMIT_MAX || 60);

  return rateLimit({
    windowMs,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    message: { ok: false, error: "rate_limited" }
  });
}
