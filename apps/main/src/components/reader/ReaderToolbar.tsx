import React, { useEffect, useRef, useState } from "react";

interface ReaderToolbarProps {
  children: React.ReactNode;
  /** Additional left-side content (e.g., TOC toggle) */
  leftContent?: React.ReactNode;
  /** Keep toolbar visible when panels are open */
  panelsOpen?: boolean;
}

export function ReaderToolbar({
  children,
  leftContent,
  panelsOpen = false,
}: ReaderToolbarProps) {
  const [toolbarVisible, setToolbarVisible] = useState(true);
  const toolbarTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Show toolbar when mouse is near the top 60px of the window (Apple Books style)
  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (e.clientY < 60) {
        setToolbarVisible(true);
        if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current);
      } else {
        if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current);
        toolbarTimerRef.current = setTimeout(
          () => setToolbarVisible(false),
          2000
        );
      }
    };
    window.addEventListener("mousemove", handleMouseMove);
    toolbarTimerRef.current = setTimeout(() => setToolbarVisible(false), 2000);
    return () => {
      window.removeEventListener("mousemove", handleMouseMove);
      if (toolbarTimerRef.current) clearTimeout(toolbarTimerRef.current);
    };
  }, []);

  const effectiveVisible = toolbarVisible || panelsOpen;

  const style: React.CSSProperties = {
    opacity: effectiveVisible ? 1 : 0,
    transition: "opacity 0.3s ease",
    pointerEvents: effectiveVisible ? "auto" : "none",
    height: 44,
    background:
      "linear-gradient(to bottom, rgba(255,255,255,0.9) 0%, rgba(255,255,255,0) 100%)",
  };

  // When there's no leftContent, only render right-aligned buttons
  // so we don't block anything underneath on the left side
  if (!leftContent) {
    return (
      <div
        className="fixed top-0 right-0 z-50 flex items-center px-4 pt-2"
        style={style}
      >
        <div className="flex items-center gap-1">{children}</div>
      </div>
    );
  }

  return (
    <div
      className="fixed top-0 left-0 right-0 z-50 flex items-center px-4 pt-2"
      style={{ ...style, pointerEvents: "none" }}
    >
      <div
        className="flex items-center"
        style={{ pointerEvents: effectiveVisible ? "auto" : "none", marginLeft: 64 }}
      >
        {leftContent}
      </div>
      <div
        className="ml-auto flex items-center gap-1"
        style={{ pointerEvents: effectiveVisible ? "auto" : "none" }}
      >
        {children}
      </div>
    </div>
  );
}
