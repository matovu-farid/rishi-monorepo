export class GlobalLimiter {
  private buckets = new Map<string, { count: number; resetAt: number }>();
  constructor(private opts: { capacity: number; windowMs: number }) {}
  allow(key: string, now = Date.now()): boolean {
    const cur = this.buckets.get(key);
    if (!cur || cur.resetAt <= now) {
      this.buckets.set(key, { count: 1, resetAt: now + this.opts.windowMs });
      return true;
    }
    if (cur.count >= this.opts.capacity) return false;
    cur.count += 1;
    return true;
  }
}
