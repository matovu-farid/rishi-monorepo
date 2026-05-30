export interface RateBucketOpts { capacity: number; refillPerSec: number; }

export class RateBucket {
  private tokens: number;
  private lastRefillMs: number;
  constructor(private opts: RateBucketOpts) {
    this.tokens = opts.capacity;
    this.lastRefillMs = Date.now();
  }
  tryConsume(now = Date.now()): boolean {
    const elapsed = (now - this.lastRefillMs) / 1000;
    this.tokens = Math.min(this.opts.capacity, this.tokens + elapsed * this.opts.refillPerSec);
    this.lastRefillMs = now;
    if (this.tokens < 1) return false;
    this.tokens -= 1;
    return true;
  }
}
