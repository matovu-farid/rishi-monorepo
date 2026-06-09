export type BillingStatusBucket =
  | "past_due"
  | "canceled"
  | "incomplete"
  | "unknown";

export interface BillingStatusCopy {
  title: string;
  body: string;
  ctaLabel: string;
}

export function getBillingStatusBucket(
  status: string | null | undefined,
): BillingStatusBucket {
  switch (status) {
    case "past_due":
    case "unpaid":
      return "past_due";
    case "canceled":
      return "canceled";
    case "incomplete":
    case "incomplete_expired":
      return "incomplete";
    default:
      return "unknown";
  }
}

const COPY: Record<BillingStatusBucket, BillingStatusCopy> = {
  past_due: {
    title: "Payment failed",
    body: "We couldn't charge your card. Update your payment method to keep using premium features.",
    ctaLabel: "Update payment method",
  },
  canceled: {
    title: "Subscription canceled",
    body: "Your subscription was canceled. Reactivate it to keep using premium features.",
    ctaLabel: "Reactivate subscription",
  },
  incomplete: {
    title: "Finish setting up billing",
    body: "Your subscription setup didn't complete. Finish payment to unlock premium features.",
    ctaLabel: "Complete setup",
  },
  unknown: {
    title: "Subscription required",
    body: "An active subscription is required to use this feature.",
    ctaLabel: "Manage subscription",
  },
};

export function getBillingStatusCopy(
  bucket: BillingStatusBucket,
): BillingStatusCopy {
  return COPY[bucket];
}
