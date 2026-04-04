import { Atom, atom } from "jotai";

import { freezeAtom } from "jotai/utils";

export function freezeAtomCreator<
  CreateAtom extends (...args: unknown[]) => Atom<unknown>,
>(createAtom: CreateAtom): CreateAtom {
  return ((...args: unknown[]) => freezeAtom(createAtom(...args))) as never;
}
