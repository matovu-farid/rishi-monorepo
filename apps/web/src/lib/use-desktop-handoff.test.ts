import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { renderHook } from "@testing-library/react"

const mockUseSession = vi.fn()
const mockUseSearchParams = vi.fn()

vi.mock("@/lib/auth-client", () => ({
  useSession: () => mockUseSession(),
}))
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
}))

import {
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
    expect(result.current).toEqual({
      isDesktopFlow: false,
      status: "inactive",
      errorMsg: "",
    })
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
})
