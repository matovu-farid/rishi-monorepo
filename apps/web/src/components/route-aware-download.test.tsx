import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mockUsePathname = vi.fn();

vi.mock("next/navigation", () => ({
  usePathname: () => mockUsePathname(),
}));

import { RouteAwareDownload } from "./route-aware-download";

describe("<RouteAwareDownload>", () => {
  beforeEach(() => mockUsePathname.mockReturnValue("/"));

  it("removes the download control on the homepage", () => {
    render(<RouteAwareDownload><span data-testid="download-control">Download</span></RouteAwareDownload>);
    expect(screen.queryByTestId("download-control")).toBeNull();
  });

  it.each(["/docs", "/support", "/pricing"])("preserves the control on %s", (pathname) => {
    mockUsePathname.mockReturnValue(pathname);
    render(<RouteAwareDownload><span data-testid="download-control">Download</span></RouteAwareDownload>);
    expect(screen.getByTestId("download-control")).toBeTruthy();
  });
});
