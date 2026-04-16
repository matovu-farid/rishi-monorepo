// apps/main/src/types/reader.test-d.ts
import { expectTypeOf } from 'vitest';
import type {
  BookContent, ReflowableContent, PagedContent, Chapter,
  Location, Paragraph, SelectionInfo, SerializedSelection, AdapterState,
} from './reader';

declare const c: BookContent;
if (c.kind === 'reflowable') expectTypeOf(c).toExtend<ReflowableContent>();
if (c.kind === 'paged')      expectTypeOf(c).toExtend<PagedContent>();

declare const l: Location;
if (l.kind === 'reflowable') expectTypeOf(l).toHaveProperty('chapterId');
if (l.kind === 'paged')      expectTypeOf(l).toHaveProperty('pageIndex');

declare const s: SerializedSelection;
expectTypeOf(JSON.stringify(s)).toEqualTypeOf<string>();

// Verify remaining exports are present
declare const _chapter: Chapter;
declare const _paragraph: Paragraph;
declare const _selectionInfo: SelectionInfo;
declare const _adapterState: AdapterState;
expectTypeOf(_chapter).toHaveProperty('id');
expectTypeOf(_paragraph).toHaveProperty('text');
expectTypeOf(_selectionInfo).toHaveProperty('serialized');
expectTypeOf(_adapterState).toHaveProperty('status');
