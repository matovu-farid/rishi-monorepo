import { drizzle } from "drizzle-orm/d1";
import { relations } from "./relations";
export function createDb(d1) {
    return drizzle(d1, { relations });
}
