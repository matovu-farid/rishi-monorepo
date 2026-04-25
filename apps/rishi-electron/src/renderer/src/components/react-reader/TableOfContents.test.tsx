import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { TableOfContents, type TocItem } from "./TableOfContents";

const sampleToc: TocItem[] = [
  {
    label: "Chapter 1",
    href: "ch1.xhtml",
    subitems: [
      { label: "Section 1.1", href: "ch1-s1.xhtml" },
      { label: "Section 1.2", href: "ch1-s2.xhtml" },
    ],
  },
  { label: "Chapter 2", href: "ch2.xhtml" },
];

describe("TableOfContents", () => {
  it("does not render when isOpen is false", () => {
    const { container } = render(
      <TableOfContents
        toc={sampleToc}
        onNavigate={vi.fn()}
        isOpen={false}
        onClose={vi.fn()}
      />,
    );
    expect(container.innerHTML).toBe("");
  });

  it("renders TOC items when isOpen is true", () => {
    render(
      <TableOfContents
        toc={sampleToc}
        onNavigate={vi.fn()}
        isOpen={true}
        onClose={vi.fn()}
      />,
    );
    expect(screen.getByText("Chapter 1")).toBeInTheDocument();
    expect(screen.getByText("Chapter 2")).toBeInTheDocument();
    expect(screen.getByText("Section 1.1")).toBeInTheDocument();
    expect(screen.getByText("Section 1.2")).toBeInTheDocument();
  });

  it("renders the 'Table of Contents' heading", () => {
    render(
      <TableOfContents
        toc={sampleToc}
        onNavigate={vi.fn()}
        isOpen={true}
        onClose={vi.fn()}
      />,
    );
    expect(screen.getByText("Table of Contents")).toBeInTheDocument();
  });

  it("calls onNavigate and onClose when a TOC item is clicked", () => {
    const onNavigate = vi.fn();
    const onClose = vi.fn();
    render(
      <TableOfContents
        toc={sampleToc}
        onNavigate={onNavigate}
        isOpen={true}
        onClose={onClose}
      />,
    );
    fireEvent.click(screen.getByText("Chapter 2"));
    expect(onNavigate).toHaveBeenCalledWith("ch2.xhtml");
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("calls onNavigate with nested item href", () => {
    const onNavigate = vi.fn();
    render(
      <TableOfContents
        toc={sampleToc}
        onNavigate={onNavigate}
        isOpen={true}
        onClose={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByText("Section 1.1"));
    expect(onNavigate).toHaveBeenCalledWith("ch1-s1.xhtml");
  });

  it("calls onClose when backdrop is clicked", () => {
    const onClose = vi.fn();
    render(
      <TableOfContents
        toc={sampleToc}
        onNavigate={vi.fn()}
        isOpen={true}
        onClose={onClose}
      />,
    );
    const backdrop = screen.getByTestId("toc-backdrop");
    fireEvent.click(backdrop);
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("renders empty TOC without errors", () => {
    const { container } = render(
      <TableOfContents
        toc={[]}
        onNavigate={vi.fn()}
        isOpen={true}
        onClose={vi.fn()}
      />,
    );
    expect(container.innerHTML).toBeTruthy();
    expect(screen.getByText("Table of Contents")).toBeInTheDocument();
  });
});
