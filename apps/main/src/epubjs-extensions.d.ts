import type { Contents } from "epubjs";
import type Section from "epubjs/types/section";
import type { SpineItem } from "epubjs/types/section";
import type View from "epubjs/types/managers/view";
import type Layout from "epubjs/types/layout";
import type Manager from "epubjs/types/managers/manager";
import type Mapping from "epubjs/types/mapping";
import type Rendition from "epubjs/types/rendition";
import type Annotations from "epubjs/types/annotations";
import type { EpubCFI } from "epubjs";

declare module "epubjs/types/section" {
  export interface SpineItem {
    load(request: (url: string) => Promise<any>): Promise<Section>;
    index: number;
    cfiBase: string;
    next(): SpineItem | null;
    prev(): SpineItem | null;
  }

  export interface Spine {
    spineItems: SpineItem[];
  }

  export default interface Section {
    pages?: number[];
    totalPages?: number;
    mapping?: {
      start: string;
      end: string;
    };
    document?: Document;
    index: number;
    load(request?: Function): Promise<Section>;
    next(): SpineItem | null;
    prev(): SpineItem | null;
  }
}

declare module "epubjs/types/managers/view" {
  export interface ViewPosition {
    left: number;
    width: number;
    right: number;
  }

  export default interface View {
    contents: Contents;
    section: Section;
    index: number;
    position(): ViewPosition;
    element: HTMLDivElement;
  }
}

declare module "epubjs/types/annotations" {
  export default interface Annotations {
    _annotations: Record<string, any>;
    highlight(
      cfiRange: string | EpubCFI,
      data?: Record<string, unknown>,
      cb?: () => void,
      className?: string,
      styles?: Record<string, unknown>
    ): any;
    remove(cfiRange: string | EpubCFI, type: string): void;
  }
}

declare module "epubjs/types/layout" {
  export default interface Layout {
    pageWidth: number;
    width: number;
    height: number;
  }
}

declare module "epubjs/types/managers/manager" {
  import type { SpineItem } from "epubjs/types/section";

  export default interface Manager {
    views: View[] & {
      find: ({ index }: { index: number }) => View | undefined;
    };
    layout: Layout;
    currentLocation(): Section[];
    mapping: Mapping;
    visible(): View[];
    add(section: Section | SpineItem, forceRight: boolean): Promise<View>;
    container: HTMLElement;
    settings: {
      axis: "horizontal" | "vertical";
      fullsize?: boolean;
      direction?: "rtl" | "ltr";
      [key: string]: any;
    };
  }
}

declare module "epubjs/types/rendition" {
  import type { Book } from "epubjs";

  export default interface Rendition {
    manager: Manager;
    annotations: Annotations;
    book: Book;
    settings: {
      ignoreClass: string;
      [key: string]: any;
    };
  }
}

declare module "epubjs/types/mapping" {
  export default interface Mapping {
    page(
      contents: Contents,
      cfiBase: string,
      start: number,
      end: number
    ): { start: string; end: string } | null;
  }
}

declare module "epubjs" {
  import type { SpineItem, Spine } from "epubjs/types/section";

  // Augment the Book interface to include loaded.spine with Spine type
  export interface Book {
    loaded: {
      spine: Promise<Spine>;
      navigation: Promise<{ toc: any[] }>;
    };
    spine: {
      each: (callback: (item: SpineItem) => void) => void;
    };
    load: (url: string) => Promise<any>;
    destroy: () => void;
  }
}
