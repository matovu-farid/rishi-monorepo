import { useCallback, useEffect, useState } from 'react';
import {
  Popover,
  PopoverTrigger,
  PopoverContent,
} from '@components/components/ui/popover';
import { Slider } from '@components/components/ui/slider';
import { Button } from '@components/components/ui/button';
import { Separator } from '@components/components/ui/separator';
import {
  Tooltip,
  TooltipTrigger,
  TooltipContent,
} from '@components/components/ui/tooltip';
import { Settings, RotateCcw } from 'lucide-react';
import { load } from '@tauri-apps/plugin-store';
import type { Rendition } from 'epubjs/types';

const DEFAULT_FONT_SIZE = 1.2;
const SERIF_FAMILY = 'Georgia, serif';
const SANS_FAMILY = 'system-ui, -apple-system, sans-serif';

interface ReaderSettingsProps {
  rendition: Rendition | null;
}

export function ReaderSettings({ rendition }: ReaderSettingsProps) {
  const [fontSize, setFontSize] = useState(DEFAULT_FONT_SIZE);
  const [fontFamily, setFontFamily] = useState(SANS_FAMILY);

  // Load persisted settings on mount
  useEffect(() => {
    void (async () => {
      try {
        const store = await load('reader-settings');
        const savedSize = await store.get<number>('fontSize');
        const savedFamily = await store.get<string>('fontFamily');
        if (savedSize != null) setFontSize(savedSize);
        if (savedFamily != null) setFontFamily(savedFamily);
      } catch {
        // Store may not exist yet -- use defaults
      }
    })();
  }, []);

  // Apply settings to rendition whenever they or rendition change
  useEffect(() => {
    if (!rendition) return;
    rendition.themes.override('font-size', `${fontSize}em`);
    rendition.themes.override('font-family', fontFamily);
  }, [rendition, fontSize, fontFamily]);

  const persist = useCallback(
    async (size: number, family: string) => {
      try {
        const store = await load('reader-settings');
        await store.set('fontSize', size);
        await store.set('fontFamily', family);
        await store.save();
      } catch {
        // Silent fail -- settings just won't persist
      }
    },
    []
  );

  const handleFontSizeChange = (value: number[]) => {
    const newSize = Math.round(value[0] * 10) / 10;
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
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="icon" aria-label="Reader settings">
          <Settings size={20} />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-[280px]">
        {/* Font Size */}
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-xs">Font Size</span>
            <div className="flex items-center gap-1">
              <span className="text-xs text-muted-foreground">
                {fontSize}em
              </span>
              {fontSize !== DEFAULT_FONT_SIZE && (
                <Tooltip>
                  <TooltipTrigger asChild>
                    <button
                      className="p-0.5 rounded hover:bg-accent"
                      onClick={handleResetFontSize}
                      aria-label="Reset to default"
                    >
                      <RotateCcw size={14} />
                    </button>
                  </TooltipTrigger>
                  <TooltipContent>Reset to default</TooltipContent>
                </Tooltip>
              )}
            </div>
          </div>
          <Slider
            min={0.8}
            max={2.0}
            step={0.1}
            value={[fontSize]}
            onValueChange={handleFontSizeChange}
          />
        </div>

        <Separator className="my-3" />

        {/* Font Family */}
        <div className="space-y-2">
          <span className="text-xs">Font Family</span>
          <div className="flex gap-2">
            <Button
              variant={fontFamily === SERIF_FAMILY ? 'default' : 'outline'}
              size="sm"
              className="flex-1"
              style={{ fontFamily: 'Georgia, serif' }}
              onClick={() => handleFontFamilyChange(SERIF_FAMILY)}
            >
              Serif
            </Button>
            <Button
              variant={fontFamily === SANS_FAMILY ? 'default' : 'outline'}
              size="sm"
              className="flex-1"
              style={{ fontFamily: 'system-ui, sans-serif' }}
              onClick={() => handleFontFamilyChange(SANS_FAMILY)}
            >
              Sans
            </Button>
          </div>
        </div>
      </PopoverContent>
    </Popover>
  );
}
