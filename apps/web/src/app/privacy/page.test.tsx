import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import PrivacyPolicy from "./page";

describe("PrivacyPolicy", () => {
  it("explains the cloud-sync, AI-provider, cache, and telemetry data flows", () => {
    render(<PrivacyPolicy />);

    expect(
      screen.getByRole("heading", { name: /privacy policy/i }),
    ).toBeInTheDocument();
    expect(screen.getAllByText(/books and documents.*cover images/i)).toHaveLength(2);
    expect(screen.getByText(/OpenAI:/i)).toBeInTheDocument();
    expect(screen.getByText(/ElevenLabs:/i)).toBeInTheDocument();
    expect(screen.getByText(/Deepgram:/i)).toBeInTheDocument();
    expect(screen.getByText(/Cloudflare R2/i)).toBeInTheDocument();
    expect(screen.getAllByText(/conversation messages/i)).toHaveLength(2);
    expect(screen.getByText(/Sentry on the web service and worker/i)).toBeInTheDocument();
    expect(screen.getByText(/does not promise a specific retention period/i)).toBeInTheDocument();

    expect(
      screen.queryByText(/raw audio is not retained after the voice session/i),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByText(/does not use any analytics frameworks/i),
    ).not.toBeInTheDocument();
  });
});
