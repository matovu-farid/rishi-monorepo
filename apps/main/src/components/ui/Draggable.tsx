import { useEffect, useState, useRef, useCallback, ReactNode } from "react";
import { load } from "@tauri-apps/plugin-store";

interface DraggableProps {
  storePath: string;
  storeKey: string;
  defaultPosition: () => { x: number; y: number };
  width: number;
  height: number;
  children: ReactNode;
  className?: string;
  excludeSelectors?: string[];
  onDragStart?: () => void;
  onDragEnd?: () => void;
}

export default function Draggable({
  storePath,
  storeKey,
  defaultPosition,
  width,
  height,
  children,
  className = "",
  excludeSelectors = [
    "button",
    "[role='button']",
    "BUTTON",
    "svg",
    "[data-no-drag]",
  ],
  onDragStart,
  onDragEnd,
}: DraggableProps) {
  const [position, setPosition] = useState<{ x: number; y: number } | null>(
    null
  );
  const [isDragging, setIsDragging] = useState(false);
  const dragRef = useRef<HTMLDivElement>(null);
  const dragStartPos = useRef<{ x: number; y: number } | null>(null);
  const dragOffset = useRef<{ x: number; y: number }>({ x: 0, y: 0 });

  // Constrain position within viewport bounds
  const constrainPosition = useCallback(
    (x: number, y: number) => {
      if (typeof window === "undefined") {
        return { x: 0, y: 0 };
      }

      const minX = 0;
      const minY = 0;
      const maxX = window.innerWidth - width;
      const maxY = window.innerHeight - height;

      return {
        x: Math.max(minX, Math.min(maxX, x)),
        y: Math.max(minY, Math.min(maxY, y)),
      };
    },
    [width, height]
  );

  // Load saved position from Tauri Store on mount
  useEffect(() => {
    const loadPosition = async () => {
      try {
        const store = await load(storePath, { defaults: {}, autoSave: false });
        const savedPosition = await store.get<{ x: number; y: number }>(
          storeKey
        );

        if (
          savedPosition &&
          typeof savedPosition.x === "number" &&
          typeof savedPosition.y === "number"
        ) {
          // Validate saved position is within viewport
          const constrained = constrainPosition(
            savedPosition.x,
            savedPosition.y
          );
          setPosition(constrained);
        } else {
          // No saved position, use default
          setPosition(defaultPosition());
        }
      } catch (error) {
        console.error(
          `Failed to load position from store (${storePath}/${storeKey}):`,
          error
        );
        // Use default position if loading fails
        setPosition(defaultPosition());
      }
    };

    void loadPosition();
  }, [storePath, storeKey, defaultPosition, constrainPosition]);

  // Save position to Tauri Store
  const savePosition = useCallback(
    (x: number, y: number) => {
      void (async () => {
        try {
          const store = await load(storePath, {
            defaults: {},
            autoSave: false,
          });
          await store.set(storeKey, { x, y });
          await store.save();
        } catch (error) {
          console.error(
            `Failed to save position to store (${storePath}/${storeKey}):`,
            error
          );
        }
      })();
    },
    [storePath, storeKey]
  );

  // Handle drag start
  const handleMouseDown = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      if (!position) return;

      // Prevent dragging if clicking on excluded elements
      const target = e.target as HTMLElement;
      const shouldExclude = excludeSelectors.some((selector) => {
        if (selector === "BUTTON") {
          return target.tagName === "BUTTON";
        }
        return target.closest(selector) !== null;
      });

      if (shouldExclude) {
        return;
      }

      e.preventDefault();
      e.stopPropagation();
      setIsDragging(true);
      dragStartPos.current = { x: e.clientX, y: e.clientY };
      dragOffset.current = { x: position.x, y: position.y };
      onDragStart?.();
    },
    [position, excludeSelectors, onDragStart]
  );

  // Handle drag move
  const handleMouseMove = useCallback(
    (e: MouseEvent) => {
      if (!isDragging || !dragStartPos.current) return;

      e.preventDefault();
      e.stopPropagation();

      const deltaX = e.clientX - dragStartPos.current.x;
      const deltaY = e.clientY - dragStartPos.current.y;

      const newX = dragOffset.current.x + deltaX;
      const newY = dragOffset.current.y + deltaY;

      const constrained = constrainPosition(newX, newY);
      setPosition(constrained);
    },
    [isDragging, constrainPosition]
  );

  // Handle drag end
  const handleMouseUp = useCallback(
    (e?: MouseEvent) => {
      if (isDragging && position) {
        if (e) {
          e.preventDefault();
          e.stopPropagation();
        }
        setIsDragging(false);
        dragStartPos.current = null;
        savePosition(position.x, position.y);
        onDragEnd?.();
      }
    },
    [isDragging, position, savePosition, onDragEnd]
  );

  // Set up global mouse event listeners for dragging
  useEffect(() => {
    if (isDragging) {
      const mouseMoveHandler = (e: MouseEvent) => handleMouseMove(e);
      const mouseUpHandler = (e: MouseEvent) => handleMouseUp(e);

      window.addEventListener("mousemove", mouseMoveHandler, {
        passive: false,
      });
      window.addEventListener("mouseup", mouseUpHandler, { passive: false });
      document.body.style.userSelect = "none"; // Prevent text selection while dragging

      return () => {
        window.removeEventListener("mousemove", mouseMoveHandler);
        window.removeEventListener("mouseup", mouseUpHandler);
        document.body.style.userSelect = "";
      };
    }
  }, [isDragging, handleMouseMove, handleMouseUp]);

  // Constrain position when window is resized
  useEffect(() => {
    if (!position) return;

    const handleResize = () => {
      const constrained = constrainPosition(position.x, position.y);
      if (constrained.x !== position.x || constrained.y !== position.y) {
        setPosition(constrained);
      }
    };

    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, [position, constrainPosition]);

  // Don't render until position is calculated
  if (position === null) {
    return null;
  }

  return (
    <div
      ref={dragRef}
      className={`fixed z-50 ${className}`}
      style={{
        left: `${position.x}px`,
        top: `${position.y}px`,
        cursor: isDragging ? "grabbing" : "grab",
      }}
      onMouseDown={handleMouseDown}
      onTouchStart={(e) => {
        // Prevent touch events from bubbling to underlying swipe handlers
        e.stopPropagation();
      }}
      onTouchMove={(e) => {
        // Prevent touch events from bubbling to underlying swipe handlers
        e.stopPropagation();
      }}
      onTouchEnd={(e) => {
        // Prevent touch events from bubbling to underlying swipe handlers
        e.stopPropagation();
      }}
    >
      {children}
    </div>
  );
}
