"use client";

import { useState, type ReactNode } from "react";
import { Menu, X } from "lucide-react";

type Props = {
  downloadButton: ReactNode;
};

export function HeaderMobileMenu({ downloadButton }: Props) {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <>
      <button
        className="md:hidden"
        onClick={() => setIsOpen((v) => !v)}
        aria-label={isOpen ? "Close menu" : "Open menu"}
        aria-expanded={isOpen}
      >
        {isOpen ? <X size={24} /> : <Menu size={24} />}
      </button>

      {isOpen && (
        <div className="md:hidden border-t border-border px-6 py-4 space-y-3">
          <a
            href="#features"
            className="block text-sm text-muted-foreground hover:text-foreground transition"
          >
            Features
          </a>
          <a
            href="#howitworks"
            className="block text-sm text-muted-foreground hover:text-foreground transition"
          >
            How it Works
          </a>
          {downloadButton}
        </div>
      )}
    </>
  );
}
