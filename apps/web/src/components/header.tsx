import Image from "next/image";
import { DownloadButtonServer } from "./download-button-server";
import { HeaderMobileMenu } from "./header-mobile-menu";
import { RouteAwareDownload } from "./route-aware-download";

export async function Header() {
  return (
    <div className="w-full">
      <div className="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Image src="/brand/rishi-icon.png" alt="" width={32} height={32} className="rounded-lg" />
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
          <RouteAwareDownload>
            <DownloadButtonServer variant="header" />
          </RouteAwareDownload>
        </nav>

        <HeaderMobileMenu
          downloadButton={
            <RouteAwareDownload>
              <DownloadButtonServer variant="header" />
            </RouteAwareDownload>
          }
        />
      </div>
    </div>
  );
}
