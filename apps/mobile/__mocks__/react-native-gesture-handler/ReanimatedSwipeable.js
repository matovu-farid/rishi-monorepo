/**
 * #60 — Global mock for `react-native-gesture-handler/ReanimatedSwipeable`.
 *
 * Why this exists:
 *   - ConversationRow imports `ReanimatedSwipeable` to wrap rows in a
 *     swipe-to-delete action.
 *   - The real ReanimatedSwipeable pulls in `RNGestureHandlerModule` →
 *     `react-native-worklets` → `react-native-reanimated`, all of which
 *     contain ESM `import` statements that Jest (testEnvironment: 'node',
 *     ts-jest, no `transformIgnorePatterns`) cannot transform.
 *   - 17+ test files in __tests__/chat/ and __tests__/pdf/ transitively
 *     import ConversationRow (via the chat tab route). Mocking per-file
 *     would spray the same boilerplate across the test tree.
 *
 * Behavior:
 *   - The stub renders `renderRightActions` inline alongside `children`, so
 *     test trees that assert on the destructive action node find it without
 *     any swipe gesture activation.
 *   - Tests that need to assert on gesture-driven behavior must mock more
 *     deeply at the test level.
 */
const React = require('react')

const ReanimatedSwipeable = React.forwardRef((props, ref) => {
  const { children, renderRightActions, renderLeftActions } = props
  return React.createElement(
    'ReanimatedSwipeable',
    { ref },
    renderLeftActions ? renderLeftActions() : null,
    children,
    renderRightActions ? renderRightActions() : null,
  )
})

module.exports = {
  __esModule: true,
  default: ReanimatedSwipeable,
}
