export interface RateBucketOpts { capacity: number; refillPerSec: number; }

export class RateBucket {
  private tokens: number;
  private lastRefillMs: number;
  constructor(private opts: RateBucketOpts) {
    this.tokens = opts.capacity;
    this.lastRefillMs = Date.now();
  }
  tryConsume(amountOrNow = 1, now = Date.now()): boolean {
    // Preserve the original `tryConsume(now)` test/helper signature while
    // allowing byte buckets to consume more than one token.
    const amount = amountOrNow > 10_000_000_000 ? 1 : amountOrNow;
    if (amountOrNow > 10_000_000_000) now = amountOrNow;
    const elapsed = (now - this.lastRefillMs) / 1000;
    this.tokens = Math.min(this.opts.capacity, this.tokens + elapsed * this.opts.refillPerSec);
    this.lastRefillMs = now;
    if (amount <= 0 || this.tokens < amount) return false;
    this.tokens -= amount;
    return true;
  }
}
