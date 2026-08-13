import { redirect } from "next/navigation";

const DEFAULT_RISHI_APP_STORE_URL =
  "https://apps.apple.com/app/apple-store/id6763041630";

type ShareJoinPageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

export function buildShareStoreURL(token?: string): string {
  const target = new URL(
    process.env.NEXT_PUBLIC_RISHI_APP_STORE_URL || DEFAULT_RISHI_APP_STORE_URL,
  );
  if (token) {
    target.searchParams.set("ct", "share");
    target.searchParams.set("share_token", token);
  }
  return target.toString();
}

export default async function ShareJoinPage({ searchParams }: ShareJoinPageProps = {}) {
  const params = searchParams ? await searchParams : {};
  // `token` is the canonical share-link parameter. Accept `share_token` too
  // so a store/campaign handoff can return to this route without losing it.
  const rawToken = params.token ?? params.share_token;
  const token = Array.isArray(rawToken) ? rawToken[0] : rawToken;
  redirect(buildShareStoreURL(token));
}
