import { atom } from "jotai";
import { User } from "@/generated";
export const userAtom = atom<User | null>(null);
export const isLoggedInAtom = atom((get) => get(userAtom) !== null);
