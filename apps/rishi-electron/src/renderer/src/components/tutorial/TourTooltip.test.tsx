import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { TourTooltip } from "./TourTooltip";
import type { TourStep } from "@/stores/tutorialStore";

// Mock framer-motion to avoid animation issues in tests
vi.mock("framer-motion", () => ({
  motion: {
    div: ({
      children,
      className,
      style,
    }: React.HTMLAttributes<HTMLDivElement> & Record<string, unknown>) => (
      <div className={className} style={style as React.CSSProperties} data-testid="tour-tooltip">
        {children}
      </div>
    ),
  },
  AnimatePresence: ({ children }: { children: React.ReactNode }) => (
    <>{children}</>
  ),
}));

const mockStep: TourStep = {
  target: "test-target",
  title: "Test Step Title",
  description: "Test step description",
  position: "below",
};

describe("TourTooltip", () => {
  let mockElement: HTMLDivElement;

  beforeEach(() => {
    // Create a mock target element in the DOM
    mockElement = document.createElement("div");
    mockElement.setAttribute("data-tour", "test-target");
    Object.defineProperty(mockElement, "getBoundingClientRect", {
      value: () => ({
        top: 100,
        bottom: 140,
        left: 200,
        right: 400,
        width: 200,
        height: 40,
        x: 200,
        y: 100,
      }),
    });
    document.body.appendChild(mockElement);
  });

  afterEach(() => {
    document.body.removeChild(mockElement);
  });

  it("renders step title and description", () => {
    render(
      <TourTooltip
        step={mockStep}
        stepIndex={0}
        totalSteps={4}
        onNext={vi.fn()}
        onSkip={vi.fn()}
      />
    );

    expect(screen.getByText("Test Step Title")).toBeInTheDocument();
    expect(screen.getByText("Test step description")).toBeInTheDocument();
  });

  it("displays correct step counter", () => {
    render(
      <TourTooltip
        step={mockStep}
        stepIndex={1}
        totalSteps={4}
        onNext={vi.fn()}
        onSkip={vi.fn()}
      />
    );

    expect(screen.getByText("2 of 4")).toBeInTheDocument();
  });

  it("shows 'Done' on last step instead of 'Next'", () => {
    render(
      <TourTooltip
        step={mockStep}
        stepIndex={3}
        totalSteps={4}
        onNext={vi.fn()}
        onSkip={vi.fn()}
      />
    );

    expect(screen.getByText("Done")).toBeInTheDocument();
    expect(screen.queryByText(/Next/)).not.toBeInTheDocument();
  });

  it("shows 'Next' on non-last step", () => {
    render(
      <TourTooltip
        step={mockStep}
        stepIndex={0}
        totalSteps={4}
        onNext={vi.fn()}
        onSkip={vi.fn()}
      />
    );

    expect(screen.getByText(/Next/)).toBeInTheDocument();
  });

  it("calls onNext when Next/Done is clicked", () => {
    const onNext = vi.fn();
    render(
      <TourTooltip
        step={mockStep}
        stepIndex={0}
        totalSteps={4}
        onNext={onNext}
        onSkip={vi.fn()}
      />
    );

    fireEvent.click(screen.getByText(/Next/));
    expect(onNext).toHaveBeenCalledTimes(1);
  });

  it("calls onSkip when Skip is clicked", () => {
    const onSkip = vi.fn();
    render(
      <TourTooltip
        step={mockStep}
        stepIndex={0}
        totalSteps={4}
        onNext={vi.fn()}
        onSkip={onSkip}
      />
    );

    fireEvent.click(screen.getByText("Skip"));
    expect(onSkip).toHaveBeenCalledTimes(1);
  });

  it("shows empty description when isEmpty is true and descriptionEmpty is set", () => {
    const stepWithEmpty: TourStep = {
      ...mockStep,
      descriptionEmpty: "No items yet",
    };

    render(
      <TourTooltip
        step={stepWithEmpty}
        stepIndex={0}
        totalSteps={4}
        isEmpty={true}
        onNext={vi.fn()}
        onSkip={vi.fn()}
      />
    );

    expect(screen.getByText("No items yet")).toBeInTheDocument();
    expect(
      screen.queryByText("Test step description")
    ).not.toBeInTheDocument();
  });
});
