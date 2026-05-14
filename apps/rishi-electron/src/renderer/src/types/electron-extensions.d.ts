// Electron-specific globals not covered by the standard DOM lib.
//
// Electron's renderer exposes `path` on the `File` object for files sourced
// from drag-and-drop or `<input type="file">`. This isn't part of the W3C
// File interface, so TypeScript doesn't know about it.
//
// Why a global augmentation: every renderer-side File instance — whether
// from react-dropzone or a native file input — needs this property visible
// in the type system. Marking it optional keeps the API honest: web-only
// callers will still see `undefined`.

declare global {
  interface File {
    /** Absolute filesystem path. Electron-only — undefined in web builds. */
    readonly path?: string
  }
}

export {}
