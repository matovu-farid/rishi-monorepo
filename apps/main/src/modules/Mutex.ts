export class Mutex {
  private _locked = false;
  private queue = [] as (() => any)[];

  async lock() {

    if (!this._locked) {
      this._locked = true;
      return this._makeRelease();
    }
    return new Promise<() => void>(resolve => {
      this.queue.push(() => {
        this._locked = true;
        resolve(this._makeRelease());
      });
    });

  }
  private _makeRelease() {
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this._locked = false;
      const next = this.queue.shift();
      if (next) next();

    };

  }

}

