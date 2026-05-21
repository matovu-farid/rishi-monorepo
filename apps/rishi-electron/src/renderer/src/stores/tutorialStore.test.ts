import { describe, it, expect, beforeEach } from 'vitest'
import { useTutorialStore, TOUR_STEPS } from './tutorialStore'

describe('tutorialStore', () => {
  beforeEach(() => {
    localStorage.clear()
    useTutorialStore.setState({
      tourActive: false,
      tourStep: 0,
      tourCompleted: false,
      tourPaused: false,
      hintsShown: {}
    })
  })

  it('should start tour', () => {
    useTutorialStore.getState().startTour()
    expect(useTutorialStore.getState().tourActive).toBe(true)
    expect(useTutorialStore.getState().tourStep).toBe(0)
  })

  it('should not start tour if completed', () => {
    useTutorialStore.setState({ tourCompleted: true })
    useTutorialStore.getState().startTour()
    expect(useTutorialStore.getState().tourActive).toBe(false)
  })

  it('should advance to next step', () => {
    useTutorialStore.setState({ tourActive: true, tourStep: 0 })
    useTutorialStore.getState().nextStep()
    expect(useTutorialStore.getState().tourStep).toBe(1)
  })

  it('should complete tour at last step', () => {
    useTutorialStore.setState({ tourActive: true, tourStep: TOUR_STEPS.length - 1 })
    useTutorialStore.getState().nextStep()
    expect(useTutorialStore.getState().tourCompleted).toBe(true)
    expect(useTutorialStore.getState().tourActive).toBe(false)
  })

  it('should skip tour and persist', () => {
    useTutorialStore.getState().skipTour()
    expect(useTutorialStore.getState().tourCompleted).toBe(true)
    expect(localStorage.getItem('rishi:tour-completed')).toBe('1')
  })

  it('should reset tour', () => {
    useTutorialStore.setState({
      tourActive: true,
      tourStep: 2,
      tourPaused: true,
      tourCompleted: true,
      hintsShown: { seen: true }
    })
    localStorage.setItem('rishi:tour-completed', '1')
    localStorage.setItem('rishi:hints-seen', JSON.stringify({ seen: true }))

    useTutorialStore.getState().resetTour()

    const state = useTutorialStore.getState()
    expect(state.tourActive).toBe(false)
    expect(state.tourStep).toBe(0)
    expect(state.tourPaused).toBe(false)
    expect(state.tourCompleted).toBe(false)
    expect(state.hintsShown).toEqual({})
    expect(localStorage.getItem('rishi:tour-completed')).toBeNull()
    expect(localStorage.getItem('rishi:hints-seen')).toBeNull()
  })

  it('should dismiss hints', () => {
    useTutorialStore.getState().dismissHint('test-hint')
    expect(useTutorialStore.getState().isHintSeen('test-hint')).toBe(true)
  })
})
