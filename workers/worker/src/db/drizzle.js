import { drizzle } from "drizzle-orm/d1";
import * as schema from "@rishi/shared/schema";
export function createDb(d1) {
    return drizzle(d1, { schema });
}
