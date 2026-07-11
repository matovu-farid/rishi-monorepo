export function createDebouncer(clock, delayMs) {
    let handle = null;
    return {
        trigger(fn) {
            if (handle != null)
                clock.clearTimeout(handle);
            handle = clock.setTimeout(() => {
                handle = null;
                fn();
            }, delayMs);
        },
        cancel() {
            if (handle != null) {
                clock.clearTimeout(handle);
                handle = null;
            }
        },
        isPending() {
            return handle != null;
        }
    };
}
