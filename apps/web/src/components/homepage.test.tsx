import { render, screen } from "@testing-library/react";
import { expect, vi } from "vitest";

vi.mock("next/image", () => ({
  default: ({ alt, src, ...props }: { alt: string; src: string }) => (
    <img alt={alt} src={src} {...props} />
  ),
}));

import { Hero } from "./hero";
import { FeatureShowcase } from "./feature-showcase";
import { TextToSpeech } from "./text-to-speech";
import { TeacherMode } from "./teacher-mode";
import { HowItWorks } from "./how-it-works";
import { CTA } from "./cta";
import { Footer } from "./footer";

describe("iOS-first homepage", () => {
  it("presents the launch message without download controls", () => {
    render(
      <>
        <Hero />
        <CTA />
        <Footer />
      </>,
    );

    expect(screen.getByRole("heading", { name: /a better way to read, listen, and learn/i })).toBeTruthy();
    expect(screen.getByText(/launching soon on iphone/i)).toBeTruthy();
    expect(screen.getAllByText(/macos planned next/i).length > 0).toBe(true);
    expect(screen.queryByText(/download/i)).toBeNull();
    expect(screen.getAllByRole("link", { name: /explore the experience/i })[0].getAttribute("href")).toBe("#features");
  });

  it("uses all four iOS screenshots in their matching sections", () => {
    render(
      <>
        <FeatureShowcase />
        <TextToSpeech />
        <TeacherMode />
        <HowItWorks />
      </>,
    );

    for (const screenshot of ["library.png", "library-books.png", "reader.png", "listening.png"]) {
      expect(document.querySelector(`img[src="/screenshots/ios/${screenshot}"]`)).toBeTruthy();
    }
  });
});
