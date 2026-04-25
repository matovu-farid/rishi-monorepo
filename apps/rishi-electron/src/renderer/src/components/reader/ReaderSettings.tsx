import { useCallback, useEffect, useState } from 'react';
import { Settings, RotateCcw } from 'lucide-react';
import type { Rendition } from 'epubjs/types';

const DEFAULT_FONT_SIZE = 1.2;
const SERIF_FAMILY = 'Georgia, serif';
const SANS_FAMILY = 'system-ui, -apple-system, sans-serif';

const SETTINGS_KEY = 'rishi:reader-settings';

interface ReaderSettingsProps {
  rendition: Rendition | null;
}

export function ReaderSettings({ rendition }: ReaderSettingsProps) {
  const [fontSize, setFontSize] = useState(DEFAULT_FONT_SIZE);
  const [fontFamily, setFontFamily] = useState(SANS_FAMILY);
  const [isOpen, setIsOpen] = useState(false);

  // Load persisted settings on mount
  useEffect(() => {
    try {
      const raw = localStorage.getItem(SETTINGS_KEY);
      if (raw) {
        const saved = JSON.parse(raw) as { fontSize?: number; fontFamily?: string };
        if (saved.fontSize != null) setFontSize(saved.fontSize);
        if (saved.fontFamily != null) setFontFamily(saved.fontFamily);
      }
    } catch {
      // Use defaults
    }
  }, []);

  // Apply settings to rendition whenever they or rendition change
  useEffect(() => {
    if (!rendition) return;
    rendition.themes.override('font-size', `${fontSize}em`);
    rendition.themes.override('font-family', fontFamily);
  }, [rendition, fontSize, fontFamily]);

  const persist = useCallback((size: number, family: string) => {
    try {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify({ fontSize: size, fontFamily: family }));
    } catch {
      // Silent fail
    }
  }, []);

  const handleFontSizeChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const newSize = Math.round(parseFloat(e.target.value) * 10) / 10;
    setFontSize(newSize);
    void persist(newSize, fontFamily);
  };

  const handleResetFontSize = () => {
    setFontSize(DEFAULT_FONT_SIZE);
    void persist(DEFAULT_FONT_SIZE, fontFamily);
  };

  const handleFontFamilyChange = (family: string) => {
    setFontFamily(family);
    void persist(fontSize, family);
  };

  return (
    <div className="relative">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="p-2 rounded-md hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
        aria-label="Reader settings"
      >
        <Settings size={20} />
      </button>

      {isOpen && (
        <>
          {/* Backdrop to close popover */}
          <div className="fixed inset-0 z-40" onClick={() => setIsOpen(false)} />

          <div className="absolute right-0 top-full mt-2 z-50 bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-700 rounded-lg shadow-lg p-4 w-[280px]">
            {/* Font Size */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-xs">Font Size</span>
                <div className="flex items-center gap-1">
                  <span className="text-xs text-gray-500">{fontSize}em</span>
                  {fontSize !== DEFAULT_FONT_SIZE && (
                    <button
                      className="p-0.5 rounded hover:bg-gray-100 dark:hover:bg-gray-800"
                      onClick={handleResetFontSize}
                      aria-label="Reset to default"
                      title="Reset to default"
                    >
                      <RotateCcw size={14} />
                    </button>
                  )}
                </div>
              </div>
              <input
                type="range"
                min={0.8}
                max={2.0}
                step={0.1}
                value={fontSize}
                onChange={handleFontSizeChange}
                className="w-full accent-blue-600"
              />
            </div>

            <hr className="my-3 border-gray-200 dark:border-gray-700" />

            {/* Font Family */}
            <div className="space-y-2">
              <span className="text-xs">Font Family</span>
              <div className="flex gap-2">
                <button
                  className={`flex-1 px-3 py-1.5 text-sm rounded-md border transition-colors ${
                    fontFamily === SERIF_FAMILY
                      ? 'bg-blue-600 text-white border-blue-600'
                      : 'border-gray-300 dark:border-gray-600 hover:bg-gray-100 dark:hover:bg-gray-800'
                  }`}
                  style={{ fontFamily: 'Georgia, serif' }}
                  onClick={() => handleFontFamilyChange(SERIF_FAMILY)}
                >
                  Serif
                </button>
                <button
                  className={`flex-1 px-3 py-1.5 text-sm rounded-md border transition-colors ${
                    fontFamily === SANS_FAMILY
                      ? 'bg-blue-600 text-white border-blue-600'
                      : 'border-gray-300 dark:border-gray-600 hover:bg-gray-100 dark:hover:bg-gray-800'
                  }`}
                  style={{ fontFamily: 'system-ui, sans-serif' }}
                  onClick={() => handleFontFamilyChange(SANS_FAMILY)}
                >
                  Sans
                </button>
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
