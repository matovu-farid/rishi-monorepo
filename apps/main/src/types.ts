export interface ManifestAttr {
  id: string;
  href: string;
  "media-type": string;
  properties?: Record<string, string>;
}

export interface OPF {
  package: {
    metadata: { "dc:title": { _text: string } };
    manifest: { item: { _attributes: ManifestAttr }[] };
    spine: { itemref: { _attributes: { idref: string } }[] };
    guide: unknown;
  };
}

export interface Container {
  container: {
    rootfiles: {
      rootfile: { _attributes: { "full-path": string } };
    };
  };
}

export type Asset = "css" | "font" | "xml" | "other";
export interface Book {
  currentbookId: string | number;
  cover: string;
  spine: { idref: string; path: string; mediaType: string }[];
  title: string;
  id: string;
  internalFolderName: string;
  assets: Partial<Record<Asset, ManifestAttr[]>>;
  epubPath: string;
}

export interface Store {
  currentbookId: string | number;
  epubPath: string;
}
export type OPFFileObj = OPF["package"];

export interface ParagraphWithCFI {
  text: string;
  cfiRange: string;
}

export interface TTSRequest {
  bookId: string;
  cfiRange: string;
  text: string;
}

// Tauri window functions
declare global {
  interface Window {
    functions: {
      getBooks: () => Promise<Book[]>;
      updateCurrentBookId: (
        internalFolderName: string,
        newId: string
      ) => Promise<void>;
    };
  }
}
