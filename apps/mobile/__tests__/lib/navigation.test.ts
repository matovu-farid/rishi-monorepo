/**
 * Safe-back navigation helper (P1-B).
 *
 * Deep-link cold-start into a reader (`/reader/[id]`, `/reader/pdf/[id]`,
 * `/reader/mobi/[id]`, `/reader/djvu/[id]`) or a chat detail screen
 * (`/chat/[bookId]`) leaves the navigation stack empty. An unguarded
 * `router.back()` then strands the user on a blank screen.
 *
 * `safeBack` returns to the tabs root when the router can't go back,
 * and behaves exactly like `router.back()` otherwise.
 */
import { safeBack } from '@/lib/navigation'

type MockRouter = {
  canGoBack: jest.Mock<boolean, []>
  back: jest.Mock<void, []>
  replace: jest.Mock<void, [string]>
}

function makeRouter(canGoBack: boolean): MockRouter {
  return {
    canGoBack: jest.fn(() => canGoBack),
    back: jest.fn(),
    replace: jest.fn(),
  }
}

describe('safeBack (P1-B)', () => {
  it('calls router.back() when the stack has history', () => {
    const router = makeRouter(true)
    safeBack(router)
    expect(router.back).toHaveBeenCalledTimes(1)
    expect(router.replace).not.toHaveBeenCalled()
  })

  it('replaces to /(tabs) when the stack is empty (deep-link cold start)', () => {
    const router = makeRouter(false)
    safeBack(router)
    expect(router.replace).toHaveBeenCalledTimes(1)
    expect(router.replace).toHaveBeenCalledWith('/(tabs)')
    expect(router.back).not.toHaveBeenCalled()
  })

  it('honors a custom fallback when provided', () => {
    const router = makeRouter(false)
    safeBack(router, '/(tabs)/library')
    expect(router.replace).toHaveBeenCalledWith('/(tabs)/library')
    expect(router.back).not.toHaveBeenCalled()
  })

  it('ignores the fallback when the stack has history', () => {
    const router = makeRouter(true)
    safeBack(router, '/(tabs)/library')
    expect(router.back).toHaveBeenCalledTimes(1)
    expect(router.replace).not.toHaveBeenCalled()
  })
})
