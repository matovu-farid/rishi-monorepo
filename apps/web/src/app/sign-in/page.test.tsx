import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"

const mockUseSession = vi.fn()
const mockUseSearchParams = vi.fn()
const mockReplace = vi.fn()
const mockUsePathname = vi.fn(() => "/sign-in")
const mockSocial = vi.fn()
const mockMagicLink = vi.fn()
const mockPasskey = vi.fn()

vi.mock("@/lib/auth-client", () => ({
  useSession: () => mockUseSession(),
  signIn: { social: (...args: unknown[]) => mockSocial(...args) },
  authClient: {
    signIn: {
      magicLink: (...args: unknown[]) => mockMagicLink(...args),
      passkey: (...args: unknown[]) => mockPasskey(...args),
    },
  },
}))
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
  usePathname: () => mockUsePathname(),
  useRouter: () => ({ replace: mockReplace, push: vi.fn() }),
}))

import { __resetDesktopHandoffForTests } from "@/lib/use-desktop-handoff"
import SignInPage from "./page"

function paramsFrom(obj: Record<string, string>): URLSearchParams {
  return new URLSearchParams(obj)
}

beforeEach(() => {
  __resetDesktopHandoffForTests()
  mockReplace.mockReset()
  mockSocial.mockReset()
  mockMagicLink.mockReset()
  mockPasskey.mockReset()
  mockUseSession.mockReturnValue({ data: null, isPending: false })
  mockUseSearchParams.mockReturnValue(paramsFrom({}))
  vi.stubGlobal(
    "fetch",
    vi.fn(() => Promise.resolve(new Response("{}", { status: 200 }))),
  )
})

describe("<SignInPage>", () => {
  it("renders the form when the user is not signed in", () => {
    render(<SignInPage />)
    expect(
      screen.getByRole("heading", { name: /sign in to rishi/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByPlaceholderText(/you@example.com/i),
    ).toBeInTheDocument()
  })

  it("renders a skeleton (no form) while session is pending", () => {
    mockUseSession.mockReturnValue({ data: null, isPending: true })
    render(<SignInPage />)
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByPlaceholderText(/you@example.com/i),
    ).not.toBeInTheDocument()
  })

  it("redirects to returnTo when signed in and no desktop params", () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(paramsFrom({ returnTo: "/library" }))

    render(<SignInPage />)

    expect(mockReplace).toHaveBeenCalledWith("/library")
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
  })

  it("redirects to / when signed in with no returnTo", () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    render(<SignInPage />)
    expect(mockReplace).toHaveBeenCalledWith("/")
  })

  it("renders 'Completing sign-in' while handoff is in flight", () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "99999999-9999-4999-8999-999999999999",
      }),
    )
    // Hang fetch forever so we observe the completing state
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})))

    render(<SignInPage />)

    expect(screen.getByText(/completing sign-in/i)).toBeInTheDocument()
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
    expect(mockReplace).not.toHaveBeenCalled()
  })

  it("renders 'Return to the Rishi app' when handoff is done", async () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      }),
    )

    render(<SignInPage />)

    expect(
      await screen.findByRole("heading", { name: /you're signed in/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByText(/return to the rishi app to continue/i),
    ).toBeInTheDocument()
    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
  })

  it("renders the error panel with retry when handoff fails", async () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      }),
    )
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response("nope", { status: 500 }))),
    )

    render(<SignInPage />)

    expect(
      await screen.findByRole("heading", { name: /sign-in handoff failed/i }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole("button", { name: /try again/i }),
    ).toBeInTheDocument()
  })
})
