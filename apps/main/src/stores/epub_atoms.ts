import { atom } from "jotai";
import { ThemeType } from "@/themes/common";

// bookIdAtom is used by chat_atoms to start realtime sessions
export const bookIdAtom = atom<string>("");
bookIdAtom.debugLabel = "bookIdAtom";

// themeAtom drives the visual theme across ReaderShell, ReaderSettings, and BackButton
export const themeAtom = atom<ThemeType>(ThemeType.White);
themeAtom.debugLabel = "themeAtom";
