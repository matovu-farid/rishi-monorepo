import { type Metadata } from "next";

export const metadata: Metadata = {
  title: "Blog - Rishi Reader",
  description:
    "Insights on reading, learning, and building Rishi. Stay up to date with the latest from the Rishi Reader team.",
};

const posts = [
  {
    title: "Introducing Teacher Mode: Your AI Reading Companion",
    date: "April 2026",
    excerpt:
      "Discover how Teacher Mode transforms your reading experience with contextual explanations, vocabulary help, and guided comprehension — all powered by AI that adapts to your level.",
  },
  {
    title: "Why We Built Rishi: Making Reading More Meaningful",
    date: "March 2026",
    excerpt:
      "The story behind Rishi Reader — from frustration with existing ebook tools to building a reader that helps you truly understand and retain what you read.",
  },
  {
    title: "The Future of Digital Reading",
    date: "February 2026",
    excerpt:
      "Digital reading hasn't changed much in a decade. We explore what's next — from AI-assisted learning to seamless cross-device experiences — and how Rishi is leading the way.",
  },
];

export default function Blog() {
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-16">
        <h1 className="text-4xl font-bold mb-2">Blog</h1>
        <p className="text-muted-foreground mb-12">
          Insights on reading, learning, and building Rishi.
        </p>

        <div className="space-y-6">
          {posts.map((post) => (
            <article
              key={post.title}
              className="group relative rounded-lg border border-border bg-muted/40 p-6 transition hover:border-orange-500/40 hover:bg-muted/70"
            >
              <div className="flex items-start justify-between gap-4 mb-3">
                <h2 className="text-xl font-semibold leading-snug">
                  {post.title}
                </h2>
                <span className="shrink-0 rounded-full bg-gradient-to-r from-amber-500 to-orange-500 px-3 py-0.5 text-xs font-medium text-white">
                  Coming Soon
                </span>
              </div>
              <p className="text-sm text-muted-foreground mb-3">{post.date}</p>
              <p className="text-base leading-relaxed text-muted-foreground">
                {post.excerpt}
              </p>
            </article>
          ))}
        </div>

        <div className="mt-16 text-center">
          <p className="text-muted-foreground">
            More posts are on the way. Stay tuned.
          </p>
        </div>
      </div>
    </main>
  );
}
