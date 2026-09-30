export class JobQueue {
  #concurrency;
  #active = 0;
  #pending = [];

  constructor(concurrency = 2) {
    this.#concurrency = concurrency;
  }

  get stats() {
    return { active: this.#active, pending: this.#pending.length, concurrency: this.#concurrency };
  }

  enqueue(task) {
    return new Promise((resolve, reject) => {
      this.#pending.push({ task, resolve, reject });
      this.#drain();
    });
  }

  #drain() {
    while (this.#active < this.#concurrency && this.#pending.length > 0) {
      const item = this.#pending.shift();
      this.#active += 1;
      Promise.resolve()
        .then(item.task)
        .then(item.resolve, item.reject)
        .finally(() => {
          this.#active -= 1;
          this.#drain();
        });
    }
  }
}
