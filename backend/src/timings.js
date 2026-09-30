import { performance } from 'node:perf_hooks';

export function elapsedMilliseconds(startedAt) {
  return Math.round((performance.now() - startedAt) * 10) / 10;
}

export class TimingRecorder {
  #limit;
  #entries = [];

  constructor(limit = 100) {
    this.#limit = limit;
  }

  record(operation, durationMs, ok = true, details = {}) {
    const safeDetails = Object.fromEntries(
      Object.entries(details).filter(([, value]) =>
        typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean'),
    );
    this.#entries.push({
      operation,
      durationMs: Math.round(Number(durationMs) * 10) / 10,
      ok: Boolean(ok),
      at: new Date().toISOString(),
      ...safeDetails,
    });
    if (this.#entries.length > this.#limit) {
      this.#entries.splice(0, this.#entries.length - this.#limit);
    }
  }

  snapshot() {
    const entries = this.#entries.map((entry) => ({ ...entry }));
    const grouped = new Map();
    for (const entry of entries) {
      const values = grouped.get(entry.operation) ?? [];
      values.push(entry.durationMs);
      grouped.set(entry.operation, values);
    }
    const summary = {};
    for (const [operation, values] of grouped) {
      const sorted = [...values].sort((left, right) => left - right);
      const total = values.reduce((sum, value) => sum + value, 0);
      summary[operation] = {
        count: values.length,
        averageMs: Math.round((total / values.length) * 10) / 10,
        p50Ms: sorted[Math.floor((sorted.length - 1) * 0.5)],
        p95Ms: sorted[Math.floor((sorted.length - 1) * 0.95)],
      };
    }
    return { summary, recent: entries.slice().reverse() };
  }
}
