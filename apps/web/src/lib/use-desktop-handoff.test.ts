import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { act, renderHook } from "@testing-library/react"

const mockUseSession = vi.fn()
const mockUseSearchParams = vi.fn()

vi.mock("@/lib/auth-client", () => ({
  useSession: () => mockUseSession(),
}))
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
}))

import {
  clearHandoff,
  useDesktopHandoff,
  __resetDesktopHandoffForTests,
} from "./use-desktop-handoff"

function paramsFrom(obj: Record<string, string>): URLSearchParams {
  return new URLSearchParams(obj)
}

beforeEach(() => {
  __resetDesktopHandoffForTests()
  mockUseSession.mockReturnValue({ data: null, isPending: false })
  mockUseSearchParams.mockReturnValue(paramsFrom({}))
  vi.stubGlobal("fetch", vi.fn())
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe("useDesktopHandoff", () => {
  it("returns inactive when no desktop params are present", () => {
    const { result } = renderHook(() => useDesktopHandoff())
    expect(result.current).toMatchObject({
      isDesktopFlow: false,
      status: "inactive",
      errorMsg: "",
    })
    expect(typeof result.current.retry).toBe("function")
  })

  it("returns waiting when params are present but session has not arrived", () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "11111111-1111-4111-8111-111111111111",
      }),
    )
    mockUseSession.mockReturnValue({ data: null, isPending: false })

    const { result } = renderHook(() => useDesktopHandoff())

    expect(result.current.isDesktopFlow).toBe(true)
    expect(result.current.status).toBe("waiting")
    expect(globalThis.fetch).not.toHaveBeenCalled()
  })

  it("treats a malformed state param as not-a-desktop-flow", () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({ login: "true", state: "not-a-uuid" }),
    )
    mockUseSession.mockReturnValue({ data: null, isPending: false })

    const { result } = renderHook(() => useDesktopHandoff())

    expect(result.current.isDesktopFlow).toBe(false)
    expect(result.current.status).toBe("inactive")
  })

  it("POSTs to /desktop/start/complete and transitions to done", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "22222222-2222-4222-8222-222222222222",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )

    const { result } = renderHook(() => useDesktopHandoff())

    // First commit: completing
    expect(result.current.status).toBe("completing")
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toMatch(/\/desktop\/start\/complete$/)
    expect(init).toMatchObject({
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
    })
    expect(JSON.parse(init.body)).toEqual({
      state: "22222222-2222-4222-8222-222222222222",
    })

    await vi.waitFor(() => expect(result.current.status).toBe("done"))
    expect(result.current.errorMsg).toBe("")
  })

  it("transitions to error when POST returns non-2xx", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "33333333-3333-4333-8333-333333333333",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(
      new Response("nope", { status: 500 }),
    )

    const { result } = renderHook(() => useDesktopHandoff())

    await vi.waitFor(() => expect(result.current.status).toBe("error"))
    expect(result.current.errorMsg).toMatch(/handoff failed \(500\): nope/)
  })

  it("transitions to error when fetch throws", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "44444444-4444-4444-8444-444444444444",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockRejectedValue(new Error("boom"))

    const { result } = renderHook(() => useDesktopHandoff())

    await vi.waitFor(() => expect(result.current.status).toBe("error"))
    expect(result.current.errorMsg).toBe("boom")
  })

  it("POSTs exactly once when two consumers mount with the same state", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "55555555-5555-4555-8555-555555555555",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(new Response("{}", { status: 200 }))

    const a = renderHook(() => useDesktopHandoff())
    const b = renderHook(() => useDesktopHandoff())

    await vi.waitFor(() => {
      expect(a.result.current.status).toBe("done")
      expect(b.result.current.status).toBe("done")
    })

    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it("re-POSTs after clearHandoff(state) is called", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "66666666-6666-4666-8666-666666666666",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock.mockResolvedValue(new Response("{}", { status: 200 }))

    const first = renderHook(() => useDesktopHandoff())
    await vi.waitFor(() => expect(first.result.current.status).toBe("done"))
    expect(fetchMock).toHaveBeenCalledTimes(1)

    clearHandoff("66666666-6666-4666-8666-666666666666")

    const second = renderHook(() => useDesktopHandoff())
    await vi.waitFor(() => expect(second.result.current.status).toBe("done"))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it("retry() callback re-fires the POST within the same mount", async () => {
    mockUseSearchParams.mockReturnValue(
      paramsFrom({
        login: "true",
        state: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      }),
    )
    mockUseSession.mockReturnValue({
      data: { user: { id: "u_1" } },
      isPending: false,
    })
    const fetchMock = globalThis.fetch as ReturnType<typeof vi.fn>
    fetchMock
      .mockResolvedValueOnce(new Response("first failure", { status: 500 }))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }))

    const { result } = renderHook(() => useDesktopHandoff())

    await vi.waitFor(() => expect(result.current.status).toBe("error"))
    expect(fetchMock).toHaveBeenCalledTimes(1)

    act(() => {
      result.current.retry()
    })

    await vi.waitFor(() => expect(result.current.status).toBe("done"))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })
})
