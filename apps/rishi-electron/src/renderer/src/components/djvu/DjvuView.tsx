import { ArrowLeft } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { useState, useEffect, useRef } from "react";
import { getDjvuPage, getDjvuPageCount, type Book } from "@/lib/api";

interface Props {
  book: Book;
}

export default function DjvuView({ book }: Props) {
  const [pageNumber, setPageNumber] = useState(Number(book.location) || 1);
  const [pageCount, setPageCount] = useState(0);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    void getDjvuPageCount({ path: book.filepath }).then(setPageCount);
  }, [book.filepath]);

  useEffect(() => {
    void getDjvuPage({ path: book.filepath, pageNumber, dpi: 150 }).then((pixels) => {
      const canvas = canvasRef.current;
      if (!canvas || !pixels.length) return;
      // Render raw pixel data to canvas
      const size = Math.sqrt(pixels.length / 4);
      canvas.width = size;
      canvas.height = size;
      const ctx = canvas.getContext("2d");
      if (ctx) {
        const imageData = new ImageData(new Uint8ClampedArray(pixels), size, size);
        ctx.putImageData(imageData, 0, 0);
      }
    });
  }, [book.filepath, pageNumber]);

  return (
    <div className="flex flex-col h-screen">
      <div data-electron-drag-region className="flex items-center gap-2 px-4 py-2 border-b border-gray-200">
        <Link to="/" className="p-2 hover:bg-gray-100 rounded-lg"><ArrowLeft size={20} /></Link>
        <span className="text-sm font-medium truncate flex-1">{book.title}</span>
        <div className="flex items-center gap-2 text-xs text-gray-500">
          <button onClick={() => setPageNumber(Math.max(1, pageNumber - 1))} disabled={pageNumber <= 1} className="hover:text-gray-700 disabled:opacity-30">Prev</button>
          <span>{pageNumber}/{pageCount}</span>
          <button onClick={() => setPageNumber(Math.min(pageCount, pageNumber + 1))} disabled={pageNumber >= pageCount} className="hover:text-gray-700 disabled:opacity-30">Next</button>
        </div>
      </div>
      <div className="flex-1 overflow-auto flex justify-center bg-gray-100 p-4">
        <canvas ref={canvasRef} className="max-w-full" />
      </div>
    </div>
  );
}
