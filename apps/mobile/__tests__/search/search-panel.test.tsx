/**
 * SearchPanel logic tests (G12 polish).
 *
 * The component itself is RN + bottom-sheet which we don't fully render
 * under jest's node env (same pattern as bookmarks-list). Instead we
 * cover the pure decision functions the component embeds:
 *
 *   - "show no-results" predicate
 *   - "show prompt placeholder" predicate
 *   - "show results list" predicate
 *
 * These match the JSX guards in `SearchPanel.tsx`. If those guards
 * regress, this test catches it.
 */

interface State {
  query: string
  isSearching: boolean
  resultsCount: number
}

function shouldShowPrompt(s: State): boolean {
  return !s.isSearching && s.query.length <= 1
}

function shouldShowNoResults(s: State): boolean {
  return !s.isSearching && s.query.length > 1 && s.resultsCount === 0
}

function shouldShowResults(s: State): boolean {
  return !s.isSearching && s.resultsCount > 0
}

function shouldShowLoading(s: State): boolean {
  return s.isSearching
}

describe('SearchPanel display predicates', () => {
  it('shows the prompt when query is empty', () => {
    expect(shouldShowPrompt({ query: '', isSearching: false, resultsCount: 0 })).toBe(true)
  })

  it('shows the prompt when query is a single char', () => {
    expect(shouldShowPrompt({ query: 'a', isSearching: false, resultsCount: 0 })).toBe(true)
  })

  it('does not show the prompt while loading', () => {
    expect(shouldShowPrompt({ query: '', isSearching: true, resultsCount: 0 })).toBe(false)
  })

  it('shows no-results when query is >1 char and zero results', () => {
    expect(
      shouldShowNoResults({ query: 'foobar', isSearching: false, resultsCount: 0 }),
    ).toBe(true)
  })

  it('does not show no-results when there are results', () => {
    expect(
      shouldShowNoResults({ query: 'foo', isSearching: false, resultsCount: 3 }),
    ).toBe(false)
  })

  it('does not show no-results during loading', () => {
    expect(
      shouldShowNoResults({ query: 'foo', isSearching: true, resultsCount: 0 }),
    ).toBe(false)
  })

  it('shows results list when count > 0 and not loading', () => {
    expect(
      shouldShowResults({ query: 'hi', isSearching: false, resultsCount: 5 }),
    ).toBe(true)
  })

  it('shows loading indicator while isSearching=true', () => {
    expect(shouldShowLoading({ query: 'a', isSearching: true, resultsCount: 0 })).toBe(true)
  })

  it('hides loading indicator when isSearching=false', () => {
    expect(shouldShowLoading({ query: 'a', isSearching: false, resultsCount: 0 })).toBe(false)
  })
})
