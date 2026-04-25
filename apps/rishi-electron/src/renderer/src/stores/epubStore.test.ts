import { describe, it, expect, beforeEach } from "vitest";
import { useEpubStore, ThemeType } from "./epubStore";

describe("epubStore", () => {
  beforeEach(() => {
    useEpubStore.getState().reset();
  });

  it("should start with null rendition", () => {
    expect(useEpubStore.getState().rendition).toBeNull();
  });

  it("should start with empty bookId", () => {
    expect(useEpubStore.getState().bookId).toBe("");
  });

  it("should start with empty currentEpubLocation", () => {
    expect(useEpubStore.getState().currentEpubLocation).toBe("");
  });

  it("should start with White theme", () => {
    expect(useEpubStore.getState().theme).toBe(ThemeType.White);
  });

  it("should set bookId", () => {
    useEpubStore.getState().setBookId("42");
    expect(useEpubStore.getState().bookId).toBe("42");
  });

  it("should set currentEpubLocation", () => {
    useEpubStore.getState().setCurrentEpubLocation("epubcfi(/6/4!/4/2/1:0)");
    expect(useEpubStore.getState().currentEpubLocation).toBe("epubcfi(/6/4!/4/2/1:0)");
  });

  it("should set theme", () => {
    useEpubStore.getState().setTheme(ThemeType.Yellow);
    expect(useEpubStore.getState().theme).toBe(ThemeType.Yellow);

    useEpubStore.getState().setTheme(ThemeType.Dark);
    expect(useEpubStore.getState().theme).toBe(ThemeType.Dark);
  });

  it("should increment rendition count", () => {
    expect(useEpubStore.getState().renditionCount).toBe(0);
    useEpubStore.getState().incrementRenditionCount();
    expect(useEpubStore.getState().renditionCount).toBe(1);
    useEpubStore.getState().incrementRenditionCount();
    expect(useEpubStore.getState().renditionCount).toBe(2);
  });

  it("should set rendition to a mock object", () => {
    const mockRendition = { display: () => {} } as any;
    useEpubStore.getState().setRendition(mockRendition);
    expect(useEpubStore.getState().rendition).toBe(mockRendition);
  });

  it("should set paragraph rendition", () => {
    const mockRendition = { display: () => {} } as any;
    useEpubStore.getState().setParagraphRendition(mockRendition);
    expect(useEpubStore.getState().paragraphRendition).toBe(mockRendition);
  });

  it("should reset all state", () => {
    useEpubStore.getState().setBookId("42");
    useEpubStore.getState().setCurrentEpubLocation("epubcfi(/6/4)");
    useEpubStore.getState().incrementRenditionCount();
    useEpubStore.getState().setRendition({ display: () => {} } as any);

    useEpubStore.getState().reset();

    expect(useEpubStore.getState().bookId).toBe("");
    expect(useEpubStore.getState().currentEpubLocation).toBe("");
    expect(useEpubStore.getState().renditionCount).toBe(0);
    expect(useEpubStore.getState().rendition).toBeNull();
    expect(useEpubStore.getState().paragraphRendition).toBeNull();
  });

  it("should allow setting bookId multiple times", () => {
    useEpubStore.getState().setBookId("1");
    expect(useEpubStore.getState().bookId).toBe("1");
    useEpubStore.getState().setBookId("2");
    expect(useEpubStore.getState().bookId).toBe("2");
    useEpubStore.getState().setBookId("3");
    expect(useEpubStore.getState().bookId).toBe("3");
  });

  it("should cycle through all theme types", () => {
    useEpubStore.getState().setTheme(ThemeType.White);
    expect(useEpubStore.getState().theme).toBe(ThemeType.White);

    useEpubStore.getState().setTheme(ThemeType.Yellow);
    expect(useEpubStore.getState().theme).toBe(ThemeType.Yellow);

    useEpubStore.getState().setTheme(ThemeType.Dark);
    expect(useEpubStore.getState().theme).toBe(ThemeType.Dark);

    useEpubStore.getState().setTheme(ThemeType.White);
    expect(useEpubStore.getState().theme).toBe(ThemeType.White);
  });

  it("should preserve theme across reset (theme is not reset)", () => {
    useEpubStore.getState().setTheme(ThemeType.Yellow);
    useEpubStore.getState().reset();
    // Theme enum resets to default White because reset() sets everything
    // Actually, looking at the store, reset() only resets specific fields
    // and theme is NOT in the reset set, so let's verify.
    // reset sets: rendition, paragraphRendition, bookId, currentEpubLocation, renditionCount
    // theme is NOT reset -- this is correct behavior
    expect(useEpubStore.getState().theme).toBe(ThemeType.Yellow);
  });

  it("should handle empty string for currentEpubLocation", () => {
    useEpubStore.getState().setCurrentEpubLocation("");
    expect(useEpubStore.getState().currentEpubLocation).toBe("");
  });

  it("should handle complex epubcfi locations", () => {
    const complexCfi = "epubcfi(/6/14[xchapter_007]!/4/2/16/1:428)";
    useEpubStore.getState().setCurrentEpubLocation(complexCfi);
    expect(useEpubStore.getState().currentEpubLocation).toBe(complexCfi);
  });

  it("should set rendition to null explicitly", () => {
    const mockRendition = { display: () => {} } as any;
    useEpubStore.getState().setRendition(mockRendition);
    expect(useEpubStore.getState().rendition).toBe(mockRendition);
    useEpubStore.getState().setRendition(null);
    expect(useEpubStore.getState().rendition).toBeNull();
  });

  it("should increment rendition count many times", () => {
    for (let i = 0; i < 10; i++) {
      useEpubStore.getState().incrementRenditionCount();
    }
    expect(useEpubStore.getState().renditionCount).toBe(10);
  });
});
