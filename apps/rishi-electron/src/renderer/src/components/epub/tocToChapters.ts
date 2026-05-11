import type { NavItem } from 'epubjs'

export function tocToChapters(toc: NavItem[]): string[] {
  const flatten = (items: NavItem[]): string[] =>
    items.flatMap((item) => [item.label.trim(), ...(item.subitems ? flatten(item.subitems) : [])])
  return flatten(toc).filter(Boolean)
}
