import { useAtom } from 'jotai';
import { themeAtom } from '@/stores/epub_atoms';
import { fontSettingsAtom, invertedDarkModeAtom } from '@/atoms/reader';
import { themes } from '@/themes/themes';

interface ReaderSettingsProps {
  contentKind?: 'reflowable' | 'paged';
}

export function ReaderSettings({ contentKind = 'reflowable' }: ReaderSettingsProps) {
  const [theme, setTheme] = useAtom(themeAtom);
  const [fontSettings, setFontSettings] = useAtom(fontSettingsAtom);
  const [inverted, setInverted] = useAtom(invertedDarkModeAtom);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <section>
        <h3 style={{ margin: 0, fontSize: 14 }}>Theme</h3>
        <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
          {Object.keys(themes).map((key) => (
            <button key={key} onClick={() => setTheme(key as never)}
                    style={{ padding: 8, border: theme === key ? '2px solid currentColor' : '1px solid #ccc' }}>
              {key}
            </button>
          ))}
        </div>
      </section>

      {contentKind === 'reflowable' && (
        <section>
          <h3 style={{ margin: 0, fontSize: 14 }}>Font</h3>
          <label>
            Size{' '}
            <input
              type="range"
              min={12}
              max={28}
              value={fontSettings.size}
              onChange={(e) => setFontSettings({ ...fontSettings, size: Number(e.target.value) })}
            />
          </label>
          <br />
          <label>
            Line height{' '}
            <input
              type="range"
              min={1.2}
              max={2.0}
              step={0.1}
              value={fontSettings.lineHeight}
              onChange={(e) => setFontSettings({ ...fontSettings, lineHeight: Number(e.target.value) })}
            />
          </label>
          <br />
          <label>
            Family{' '}
            <select
              value={fontSettings.family}
              onChange={(e) => setFontSettings({ ...fontSettings, family: e.target.value })}
            >
              <option value="Georgia, serif">Serif</option>
              <option value="system-ui, sans-serif">Sans-serif</option>
              <option value="ui-monospace, monospace">Monospace</option>
            </select>
          </label>
        </section>
      )}

      {contentKind === 'paged' && (
        <section>
          <label>
            <input
              type="checkbox"
              checked={inverted}
              onChange={(e) => setInverted(e.target.checked)}
            />
            {' '}Dark mode for pages (inverts colors)
          </label>
        </section>
      )}
    </div>
  );
}
