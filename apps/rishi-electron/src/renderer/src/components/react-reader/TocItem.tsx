import type { NavItem } from 'epubjs'

interface TocItemProps {
  data: NavItem
  setLocation: (href: string) => void
}

/**
 * Recursive TOC item used by ReactReader's ReaderTOC content.
 * Renders a single chapter button and recurses into nested subitems.
 */
export function TocItem({ data, setLocation }: TocItemProps) {
  return (
    <div>
      <button
        onClick={() => setLocation(data.href)}
        className="block w-full text-left py-3 px-4 text-sm text-gray-700 hover:bg-gray-100 hover:pl-6 border-b border-gray-100 cursor-pointer transition-all duration-200"
      >
        {data.label}
      </button>
      {data.subitems && data.subitems.length > 0 ? (
        <div style={{ paddingLeft: 16 }}>
          {data.subitems.map((item) => (
            // `id` is the spine item identifier from epub.js — guaranteed
            // unique within a navigation tree. Falling back to `href`
            // covers malformed TOCs that omit `id`.
            <TocItem key={item.id || item.href} data={item} setLocation={setLocation} />
          ))}
        </div>
      ) : null}
    </div>
  )
}
