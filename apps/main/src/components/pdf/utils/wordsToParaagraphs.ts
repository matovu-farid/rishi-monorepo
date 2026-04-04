interface Options {
  sentencesPerParagraph?: number;
  minParagraphLength?: number; // minimum number of words required
}

/** STEP 1 — Convert list of words → sentences */
export function wordsToSentences(words: string[]): string[] {
  const sentences: string[] = [];
  let buffer: string[] = [];

  for (const word of words) {
    // Sentence starts at uppercase-starting word
    if (buffer.length === 0) {
      if (/^[A-Z]/.test(word)) {
        buffer.push(word);
      } else {
        continue;
      }
    } else {
      buffer.push(word);
    }

    // End when a word ends with "."
    if (/\.$/.test(word)) {
      sentences.push(buffer.join(" "));
      buffer = [];
    }
  }

  return sentences;
}

/** STEP 2 — Group sentences into paragraphs */
export function sentencesToParagraphs(
  sentences: string[],
  sentencesPerParagraph: number
): string[] {
  const paragraphs: string[] = [];

  for (let i = 0; i < sentences.length; i += sentencesPerParagraph) {
    const chunk = sentences.slice(i, i + sentencesPerParagraph);
    paragraphs.push(chunk.join(" "));
  }

  return paragraphs;
}

/** STEP 3 — Merge short paragraphs */
export function mergeShortParagraphs(
  paragraphs: string[],
  minLength: number
): string[] {
  if (paragraphs.length === 0) return paragraphs;

  const result = [...paragraphs];

  const getWordCount = (text: string) => text.split(/\s+/).length;

  for (let i = 0; i < result.length; i++) {
    const current = result[i];
    if (!current) continue;

    if (getWordCount(current) < minLength) {
      // Prefer merging upward
      if (i > 0) {
        result[i - 1] = result[i - 1] + " " + current;
        result[i] = "";
      }
      // Otherwise merge downward
      else if (i < result.length - 1) {
        result[i + 1] = current + " " + result[i + 1];
        result[i] = "";
      }
    }
  }

  // Remove empty strings created after merging
  return result.filter((p) => p.trim().length > 0);
}

/** MAIN HELPER */
export function wordsToFinalParagraphs(
  words: string[],
  options: Options = {}
): string[] {
  const {
    sentencesPerParagraph = 8,
    minParagraphLength = 50, // default minimum paragraph word count
  } = options;

  const sentences = wordsToSentences(words);
  const grouped = sentencesToParagraphs(sentences, sentencesPerParagraph);
  const merged = mergeShortParagraphs(grouped, minParagraphLength);

  return merged;
}
