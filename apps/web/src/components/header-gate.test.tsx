import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"

const mockUsePathname = vi.fn()

vi.mock("next/navigation", () => ({
  usePathname: () => mockUsePathname(),
}))

import { HeaderGate } from "./header-gate"

beforeEach(() => {
  mockUsePathname.mockReturnValue("/")
})

function renderGate() {
  return render(
    <HeaderGate>
      <div data-testid="site-header">header</div>
    </HeaderGate>,
  )
}

describe("<HeaderGate>", () => {
  it("renders the header on non-legal routes", () => {
    mockUsePathname.mockReturnValue("/")
    renderGate()
    expect(screen.queryByTestId("site-header")).not.toBeNull()
  })

  it.each(["/privacy", "/terms", "/legal/subscription-terms"])(
    "hides the header on legal route %s",
    (path) => {
      mockUsePathname.mockReturnValue(path)
      renderGate()
      expect(screen.queryByTestId("site-header")).toBeNull()
    },
  )

  it("hides the header on nested legal routes", () => {
    mockUsePathname.mockReturnValue("/legal/anything/deep")
    renderGate()
    expect(screen.queryByTestId("site-header")).toBeNull()
  })

  it("does not hide on routes that merely start with a legal word", () => {
    mockUsePathname.mockReturnValue("/termsly")
    renderGate()
    expect(screen.queryByTestId("site-header")).not.toBeNull()
  })
})
