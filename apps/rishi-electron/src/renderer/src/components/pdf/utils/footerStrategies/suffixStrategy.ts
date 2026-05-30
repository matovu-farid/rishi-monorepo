import { findRepeatingPageSuffix } from '../findRepeatingPageSuffix'
import type { FooterStrategy } from './types'

/**
 * Thin adapter around the existing suffix-matcher footer detector. Lifted
 * out so the orchestrator can treat it uniformly with the other strategies
 * (was previously merged in pdf.tsx via a bespoke loop).
 */
export const suffixStrategy: FooterStrategy = (pages) => findRepeatingPageSuffix(pages)
