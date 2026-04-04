import { Brain } from 'lucide-react'

export function TeacherMode() {
  return (
    <section className="py-20 px-6 md:py-32 bg-muted/30">
      <div className="max-w-4xl mx-auto">
        <div className="space-y-8 text-center">
          <div className="flex items-center justify-center gap-3">
            <Brain className="text-amber-500" size={32} />
            <span className="text-sm font-semibold text-amber-500 tracking-wide">INNOVATION</span>
          </div>

          <div>
            <h2 className="text-4xl md:text-5xl font-bold mb-6">Your book becomes your teacher</h2>
            <p className="text-xl text-muted-foreground text-pretty leading-relaxed max-w-2xl mx-auto">
              Ever read a passage and wanted to dig deeper? Ask questions about what you're reading. The AI understands the context of your book and answers from what you've already learned. No generic responses—just insights connected to your reading.
            </p>
          </div>
        </div>

        {/* Feature Grid */}
        <div className="grid md:grid-cols-2 gap-6 mt-16">
          {[
            {
              title: 'Conversational Learning',
              desc: 'Ask anything about what you\'re reading. Get explanations, examples, and deeper understanding without leaving your book.'
            },
            {
              title: 'Context-Aware Responses',
              desc: 'The AI knows your reading history and current position. Answers build on what you\'ve already learned.'
            },
            {
              title: 'Clarify Complex Ideas',
              desc: 'Struggling with a concept? Ask for simpler explanations, real-world examples, or connections to other topics.'
            },
            {
              title: 'Deepen Your Engagement',
              desc: 'Transform passive reading into active learning. Stay curious and keep exploring ideas as they come to you.'
            }
          ].map((feature, i) => (
            <div key={i} className="p-6 rounded-xl border border-border bg-card/50 hover:bg-card transition space-y-3">
              <h3 className="font-semibold text-lg text-foreground">{feature.title}</h3>
              <p className="text-muted-foreground text-sm leading-relaxed">{feature.desc}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
