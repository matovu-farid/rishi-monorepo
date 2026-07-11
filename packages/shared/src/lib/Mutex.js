export class Mutex {
    locked = false;
    waiting = [];
    async acquire() {
        if (!this.locked) {
            this.locked = true;
            return;
        }
        return new Promise((resolve) => {
            this.waiting.push(resolve);
        });
    }
    release() {
        const next = this.waiting.shift();
        if (next) {
            next();
        }
        else {
            this.locked = false;
        }
    }
}
