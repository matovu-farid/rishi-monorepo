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
    expect(globalThis.fetch).toHaveBeenCalled()
    expect(
      ((globalThis.fetch as ReturnType<typeof vi.fn>).mock
        .calls[0][0] as string),
    ).toMatch(/\/desktop\/start\/complete$/)
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

  it("auto-fires Google OAuth with a clean callbackURL (no provider=google, no &&)", () => {
    const state = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    mockUseSearchParams.mockReturnValue(
      paramsFrom({ login: "true", provider: "google", state }),
    )
    const originalHref = window.location.href
    Object.defineProperty(window, "location", {
      configurable: true,
      value: {
        ...window.location,
        href: `https://rishi.fidexa.org/sign-in?login=true&provider=google&state=${state}`,
        origin: "https://rishi.fidexa.org",
      },
    })

    try {
      render(<SignInPage />)

      expect(mockSocial).toHaveBeenCalledTimes(1)
      const arg = mockSocial.mock.calls[0][0] as {
        provider: string
        callbackURL: string
      }
      expect(arg.provider).toBe("google")
      expect(arg.callbackURL).toBe(
        `https://rishi.fidexa.org/sign-in?login=true&state=${state}`,
      )
      expect(arg.callbackURL).not.toContain("&&")
      expect(arg.callbackURL).not.toContain("provider=google")
    } finally {
      Object.defineProperty(window, "location", {
        configurable: true,
        value: { ...window.location, href: originalHref },
      })
    }
  })

  it("does not render the email magic-link form when provider=google is in the URL", () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        provider: "google",
        state: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      }),
    )

    render(<SignInPage />)

    expect(
      screen.queryByRole("heading", { name: /sign in to rishi/i }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByPlaceholderText(/you@example.com/i),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByRole("button", { name: /^continue$/i }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByRole("button", { name: /continue with google/i }),
    ).not.toBeInTheDocument()
    expect(
      screen.queryByRole("button", { name: /sign in with passkey/i }),
    ).not.toBeInTheDocument()
    expect(screen.getByTestId("sign-in-skeleton")).toBeInTheDocument()
  })

  it("clicking 'Try again' re-fires the handoff POST", async () => {
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      }),
    )
    const fetchMock = vi.fn()
    fetchMock
      .mockResolvedValueOnce(new Response("bad", { status: 500 }))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }))
    vi.stubGlobal("fetch", fetchMock)

    const user = (await import("@testing-library/user-event")).default.setup()
    render(<SignInPage />)

    const tryAgain = await screen.findByRole("button", { name: /try again/i })
    expect(fetchMock).toHaveBeenCalledTimes(1)

    await user.click(tryAgain)

    await screen.findByRole("heading", { name: /you're signed in/i })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })
})
