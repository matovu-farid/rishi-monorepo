import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"

const mockUseSession = vi.fn()
const mockUseSearchParams = vi.fn()
const mockUsePathname = vi.fn()

vi.mock("@/lib/auth-client", () => ({
  useSession: () => mockUseSession(),
}))
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
  usePathname: () => mockUsePathname(),
}))

import { __resetDesktopHandoffForTests } from "@/lib/use-desktop-handoff"
import { DesktopHandoffListener } from "./desktop-handoff-listener"

function paramsFrom(obj: Record<string, string>): URLSearchParams {
  return new URLSearchParams(obj)
}

beforeEach(() => {
  __resetDesktopHandoffForTests()
  vi.stubGlobal(
    "fetch",
    vi.fn(() => Promise.resolve(new Response("{}", { status: 200 }))),
  )
  mockUseSession.mockReturnValue({ data: null, isPending: false })
  mockUseSearchParams.mockReturnValue(paramsFrom({}))
  mockUsePathname.mockReturnValue("/")
})

describe("<DesktopHandoffListener>", () => {
  it("renders nothing on /sign-in even when desktop params are present", () => {
    mockUsePathname.mockReturnValue("/sign-in")
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "77777777-7777-4777-8777-777777777777",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })

    const { container } = render(<DesktopHandoffListener />)
    expect(container.firstChild).toBeNull()
  })

  it("renders nothing on / when no desktop params are present", () => {
    const { container } = render(<DesktopHandoffListener />)
    expect(container.firstChild).toBeNull()
  })

  it("renders the toast on / when handoff is done", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "88888888-8888-4888-8888-888888888888",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })

    render(<DesktopHandoffListener />)

    expect(await screen.findByText(/signed in/i)).toBeInTheDocument()
    expect(
      screen.getByText(/return to the rishi app to continue/i),
    ).toBeInTheDocument()
  })
})
