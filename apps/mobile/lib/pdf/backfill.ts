/**
 * Boot-time backfill: find PDF books whose extraction is missing or
 * stuck and enqueue them for extraction. Called once from app/_layout.tsx
 * on mount.
 */

import { rawDb } from '@/lib/db'
import { enqueueExtraction } from '@/lib/pdf/extraction-runner'

interface CandidateRow {
  id: string
  file_path: string
}

export async function backfillUnextractedBooks(): Promise<void> {
  const rows = rawDb.getAllSync<CandidateRow>(
    `SELECT id, file_path FROM books
       WHERE format='pdf'
         AND is_deleted=0
         AND (extraction_status IS NULL
              OR extraction_status='pending'
              OR extraction_status='extracting')`,
  )
  for (const row of rows) {
    await enqueueExtraction({ bookId: row.id, filePath: row.file_path })
  }
}
