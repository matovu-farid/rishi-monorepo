import { Redis } from "@upstash/redis";
import { atom } from "jotai";

export const redisAtom = atom<Redis | null>(null);
