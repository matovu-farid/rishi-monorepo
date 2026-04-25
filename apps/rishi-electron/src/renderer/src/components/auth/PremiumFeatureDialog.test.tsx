import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { PremiumFeatureDialog } from "./PremiumFeatureDialog";
import { useAuthStore } from "@/stores/authStore";
import { PREMIUM_FEATURES } from "./features";

// Mock auth module
vi.mock("@/modules/auth", () => ({
  startSignInFlow: vi.fn().mockResolvedValue(undefined),
  clearPendingOAuthState: vi.fn(),
}));

describe("PremiumFeatureDialog", () => {
  beforeEach(() => {
    useAuthStore.setState({ signingIn: false });
  });

  it("renders dialog with TTS feature content when open", () => {
    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={() => {}}
        feature="tts"
      />
    );

    expect(screen.getByText(PREMIUM_FEATURES.tts.title)).toBeInTheDocument();
    expect(
      screen.getByText(PREMIUM_FEATURES.tts.description)
    ).toBeInTheDocument();
    for (const bullet of PREMIUM_FEATURES.tts.bullets) {
      expect(screen.getByText(bullet)).toBeInTheDocument();
    }
  });

  it("renders dialog with chat feature content", () => {
    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={() => {}}
        feature="chat"
      />
    );

    expect(screen.getByText(PREMIUM_FEATURES.chat.title)).toBeInTheDocument();
    expect(
      screen.getByText(PREMIUM_FEATURES.chat.description)
    ).toBeInTheDocument();
  });

  it("does not render dialog when closed", () => {
    render(
      <PremiumFeatureDialog
        open={false}
        onOpenChange={() => {}}
        feature="tts"
      />
    );

    expect(
      screen.queryByText(PREMIUM_FEATURES.tts.title)
    ).not.toBeInTheDocument();
  });

  it("calls onOpenChange(false) when 'Maybe later' is clicked", () => {
    const onOpenChange = vi.fn();
    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={onOpenChange}
        feature="tts"
      />
    );

    fireEvent.click(screen.getByText("Maybe later"));
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it("shows sign-in button with correct label", () => {
    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={() => {}}
        feature="tts"
      />
    );

    expect(screen.getByText("Sign in")).toBeInTheDocument();
  });

  it("shows loading state when signing in", () => {
    useAuthStore.setState({ signingIn: true });

    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={() => {}}
        feature="tts"
      />
    );

    expect(screen.getByText(/Signing in/)).toBeInTheDocument();
  });

  it("shows Cancel button instead of Maybe later when signing in", () => {
    useAuthStore.setState({ signingIn: true });

    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={() => {}}
        feature="tts"
      />
    );

    expect(screen.getByText("Cancel")).toBeInTheDocument();
    expect(screen.queryByText("Maybe later")).not.toBeInTheDocument();
  });

  it("resets signingIn state and closes dialog when Cancel is clicked", () => {
    useAuthStore.setState({ signingIn: true });
    const onOpenChange = vi.fn();

    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={onOpenChange}
        feature="tts"
      />
    );

    fireEvent.click(screen.getByText("Cancel"));
    expect(useAuthStore.getState().signingIn).toBe(false);
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it("does not show bullets for ai-generic feature", () => {
    render(
      <PremiumFeatureDialog
        open={true}
        onOpenChange={() => {}}
        feature="ai-generic"
      />
    );

    expect(
      screen.getByText(PREMIUM_FEATURES["ai-generic"].title)
    ).toBeInTheDocument();
    // ai-generic has no bullets, so no list items should be rendered
    expect(screen.queryByRole("listitem")).not.toBeInTheDocument();
  });
});
