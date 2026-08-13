import ShareJoinFallback from "./share-join-fallback";

const DEFAULT_RISHI_APP_STORE_URL =
  "https://apps.apple.com/app/apple-store/id6763041630";

type ShareJoinPageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

export function buildShareStoreURL(): string {
  const target = new URL(
    process.env.NEXT_PUBLIC_RISHI_APP_STORE_URL || DEFAULT_RISHI_APP_STORE_URL,
  );
  return target.toString();
}

export default async function ShareJoinPage({ searchParams }: ShareJoinPageProps = {}) {
  // The client reads the token from the current URL so the bearer value is
  // never rendered into the HTML. Universal links normally skip this page;
  // when association misses, the custom-scheme attempt still reaches an
  // installed app before the App Store fallback runs.
  void searchParams;
  return <ShareJoinFallback />;
}
