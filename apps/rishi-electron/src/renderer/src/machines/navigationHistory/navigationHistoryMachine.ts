import { setup, assign } from 'xstate'
import type { NavigationHistoryContext, NavigationHistoryEvent } from './types'

const initialContext = (): NavigationHistoryContext => ({
  bookId: null,
  stack: [],
  resumeMap: new Map(),
  currentPage: null,
  pillVisible: false
})

export const navigationHistoryMachine = setup({
  types: {
    context: {} as NavigationHistoryContext,
    events: {} as NavigationHistoryEvent
  },
  actions: {
    hydrateOnOpen: assign(({ event }) => {
      if (event.type !== 'BOOK_OPENED') return {}
      return {
        bookId: event.bookId,
        currentPage: event.initialPosition,
        stack: [],
        resumeMap: new Map(),
        pillVisible: false
      }
    }),
    clearAll: assign(() => initialContext())
  }
}).createMachine({
  id: 'navigationHistory',
  initial: 'inactive',
  context: initialContext(),
  states: {
    inactive: {
      on: {
        BOOK_OPENED: { target: 'active', actions: 'hydrateOnOpen' }
      }
    },
    active: {
      on: {
        BOOK_CLOSED: { target: 'inactive', actions: 'clearAll' }
      },
      type: 'parallel',
      states: {
        stack: { initial: 'idle', states: { idle: {} } },
        engagement: { initial: 'idle', states: { idle: {} } },
        pill: { initial: 'hidden', states: { hidden: {} } }
      }
    }
  }
})
