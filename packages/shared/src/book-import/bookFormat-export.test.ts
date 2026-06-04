/**
 * Type-system gate for T-P1.5 / DRY-003.
 *
 * Verifies that `BookFormat` includes all 5 values (`'epub' | 'pdf' | 'mobi'
 * | 'azw3' | 'djvu'`) and that the type is re-exported from the package's
 * `book-import` barrel — both of which the electron adapter depends on
 * after the DRY-003 lift.
 *
 * NOTE: at the time of writing, `BookFormat` already includes `'djvu'` and
 * the barrel re-exports it, so this test is expected to be GREEN out of the
 * gate. It is included as a regression guard for future edits.
 */
import { describe, it, expectTypeOf } from "vitest";
import type { BookFormat } from "./index";

describe("BookFormat — re-exported from @rishi/shared/book-import", () => {
  it("union has exactly the 5 supported formats", () => {
    expectTypeOf<BookFormat>().toEqualTypeOf<
      "epub" | "pdf" | "mobi" | "azw3" | "djvu"
    >();
  });

  it("'djvu' is assignable to BookFormat (closes EBUG-003)", () => {
    const djvu = "djvu" as const;
    expectTypeOf(djvu).toExtend<BookFormat>();
  });

  it("each canonical literal is assignable", () => {
    const epub: BookFormat = "epub";
    const pdf: BookFormat = "pdf";
    const mobi: BookFormat = "mobi";
    const azw3: BookFormat = "azw3";
    const djvu: BookFormat = "djvu";
    // Round-trip via satisfies to keep the assertions live and avoid
    // dead-code elimination warnings.
    const all = [epub, pdf, mobi, azw3, djvu] satisfies BookFormat[];
    expectTypeOf(all).toExtend<BookFormat[]>();
  });

  it("rejects unknown formats at the type level", () => {
    // @ts-expect-error "txt" is not part of BookFormat
    const bad: BookFormat = "txt";
    void bad;
  });
});
