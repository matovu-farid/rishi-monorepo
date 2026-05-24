import { ClipLoader } from 'react-spinners'

export default function Loader() {
  // `var(--primary)` resolves against the active theme (light/dark) so the
  // spinner color matches design tokens instead of a fixed indigo literal.
  return (
    <div className="flex flex-col items-center gap-3">
      <ClipLoader color="var(--primary)" size={40} />
      <p className="text-sm text-muted-foreground">Loading...</p>
    </div>
  )
}
