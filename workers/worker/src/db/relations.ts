import { defineRelations } from "drizzle-orm";
import * as schema from "./schema";

// Relational Queries v2 (drizzle-orm@1.x) centralizes every table's relations
// into one place instead of a `relations()` call per table. See:
// https://orm.drizzle.team/docs/relations-v2
export const relations = defineRelations(schema, (r) => ({
  user: {
    appleAccounts: r.many.appleUsers(),
  },
  appleUsers: {
    user: r.one.user({
      from: r.appleUsers.userId,
      to: r.user.id,
    }),
  },
}));
