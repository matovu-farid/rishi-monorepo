import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";
import { hash } from "@intrnl/xxhash64";

// optional: choose a seed (default = 0)
const SEED = 0;

export function stringToHash64(str: string): bigint {
  return hash(str, SEED);
}

export function stringToNumberID(str: string): number {
  // xxhash64 returns a 64-bit bigint.
  // JS numbers can only safely represent 53 bits.
  const hashValue = hash(str, SEED);
  return Number(hashValue & BigInt("0x1FFFFFFFFFFFFF")); // keep lower 53 bits
}

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export async function withRetry<T>(
  { tries = 3, timeOut = 50 }: { tries?: number; timeOut?: number },
  fn: (...args: any[]) => T
) {
  let error;
  for (let i = 0; i < tries; i++) {
    try {
      return fn();
    } catch (e) {
      // Assume pure function, so store just the last error
      error = e;
      console.warn(`>>>${i}. Retrying ${fn.name}`);
      let timer;

      await new Promise((resolve) => {
        timer = setTimeout(resolve, timeOut);
      });
      clearTimeout(timer);
    }
  }
  console.error(error);
  throw error;
}
