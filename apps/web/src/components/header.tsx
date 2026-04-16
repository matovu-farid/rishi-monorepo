import { DownloadButtonServer } from "./download-button-server";
import { HeaderMobileMenu } from "./header-mobile-menu";

export async function Header() {
  return (
    <div className="w-full">
      <div className="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-amber-500 to-orange-500 flex items-center justify-center">
            <span className="text-white font-bold text-sm">R</span>
          </div>
          <span className="text-xl font-bold">Rishi</span>
        </div>

        <nav className="hidden md:flex items-center gap-8">
          <a
            href="#features"
            className="text-sm text-muted-foreground hover:text-foreground transition"
          >
            Features
          </a>
          <a
            href="#howitworks"
            className="text-sm text-muted-foreground hover:text-foreground transition"
          >
            How it Works
          </a>
          <DownloadButtonServer variant="header" />
        </nav>

        <HeaderMobileMenu downloadButton={<DownloadButtonServer variant="header" />} />
      </div>
    </div>
  );
}
