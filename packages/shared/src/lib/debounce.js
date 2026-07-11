/**
 * Debounce utility function
 * Delays invoking a function until after a specified wait time has elapsed
 * since the last time the debounced function was invoked.
 *
 * @param func - The function to debounce
 * @param wait - The number of milliseconds to delay
 * @returns A debounced version of the function
 */
// Why: T must be constrained to a variadic function type; due to parameter contravariance, replacing `any[]` with `unknown[]` or `never[]` would reject all real-world typed callers (the canonical variadic-generic shape).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function debounce(func, wait) {
    let timeout = null;
    return function executedFunction(...args) {
        const later = () => {
            timeout = null;
            func(...args);
        };
        if (timeout !== null) {
            clearTimeout(timeout);
        }
        timeout = setTimeout(later, wait);
    };
}
