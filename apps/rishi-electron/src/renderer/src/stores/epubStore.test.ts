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

    useEpubStore.getState().setTheme(ThemeType.Gray);
    expect(useEpubStore.getState().theme).toBe(ThemeType.Gray);
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
});
