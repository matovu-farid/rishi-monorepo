import { ArrowLeft } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { useState, useEffect } from "react";
import { getMobiChapter, getMobiChapterCount, type Book } from "@/lib/api";
import DOMPurify from "dompurify";

interface Props {
  book: Book;
}

export default function MobiView({ book }: Props) {
  const [chapterHtml, setChapterHtml] = useState<string>("");
  const [chapterIndex, setChapterIndex] = useState(Number(book.location) || 0);
  const [chapterCount, setChapterCount] = useState(0);

  useEffect(() => {
    void getMobiChapterCount({ path: book.filepath }).then(setChapterCount);
  }, [book.filepath]);

  useEffect(() => {
    void getMobiChapter({ path: book.filepath, chapterIndex }).then(setChapterHtml);
  }, [book.filepath, chapterIndex]);

  return (
    <div className="flex flex-col h-screen">
      <div data-electron-drag-region className="flex items-center gap-2 px-4 py-2 border-b border-gray-200">
        <Link to="/" className="p-2 hover:bg-gray-100 rounded-lg">
          <ArrowLeft size={20} />
        </Link>
        <span className="text-sm font-medium truncate flex-1">{book.title}</span>
        <div className="flex items-center gap-2 text-xs text-gray-500">
          <button onClick={() => setChapterIndex(Math.max(0, chapterIndex - 1))} disabled={chapterIndex <= 0} className="hover:text-gray-700 disabled:opacity-30">Prev</button>
          <span>Ch {chapterIndex + 1}/{chapterCount}</span>
          <button onClick={() => setChapterIndex(Math.min(chapterCount - 1, chapterIndex + 1))} disabled={chapterIndex >= chapterCount - 1} className="hover:text-gray-700 disabled:opacity-30">Next</button>
        </div>
      </div>
      <div className="flex-1 overflow-auto p-8 max-w-2xl mx-auto">
        {/* Sanitize MOBI HTML - files are user-supplied and could contain malicious content */}
        <div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(chapterHtml) }} className="prose prose-sm" />
      </div>
    </div>
  );
}
