import { redirect } from "next/navigation";

const DEFAULT_RISHI_APP_STORE_URL =
  "https://apps.apple.com/app/apple-store/id6763041630";

export default function ShareJoinPage() {
  redirect(
    process.env.NEXT_PUBLIC_RISHI_APP_STORE_URL || DEFAULT_RISHI_APP_STORE_URL,
  );
}
