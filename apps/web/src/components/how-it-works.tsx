import { BookOpen, Ear, MessageSquare } from 'lucide-react'

export function HowItWorks() {
  return (
    <section id="howitworks" className="py-20 px-6 md:py-32">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-16">
          <h2 className="text-4xl md:text-5xl font-bold mb-4">Three simple steps</h2>
          <p className="text-lg text-muted-foreground text-pretty">
            A simple flow for turning reading time into learning time.
          </p>
        </div>

        <div className="grid md:grid-cols-3 gap-8">
          {[
            {
              icon: BookOpen,
              step: '1',
              title: 'Add a book',
              desc: 'Bring a book into your library and make it part of your everyday rhythm.'
            },
            {
              icon: Ear,
              step: '2',
              title: 'Read or listen',
              desc: 'Move between reading and listening whenever the moment calls for it.'
            },
            {
              icon: MessageSquare,
              step: '3',
              title: 'Ask and go deeper',
              desc: 'Follow your curiosity with contextual questions, explanations, and new connections.'
            }
          ].map((item, i) => {
            const Icon = item.icon
            return (
              <div key={i} className="relative">
                {i < 2 && (
                  <div className="absolute top-12 left-1/2 w-1/3 h-0.5 bg-gradient-to-r from-amber-500 to-transparent -z-10 hidden md:block"></div>
                )}
                <div className="space-y-4 text-center">
                  <div className="flex justify-center">
                    <div className="w-16 h-16 rounded-xl bg-gradient-to-br from-amber-500 to-orange-500 flex items-center justify-center text-white">
                      <Icon size={32} />
                    </div>
                  </div>
                  <div className="text-4xl font-bold text-amber-500">{item.step}</div>
                  <h3 className="text-xl font-semibold text-foreground">{item.title}</h3>
                  <p className="text-muted-foreground text-pretty leading-relaxed">{item.desc}</p>
                </div>
              </div>
            )
          })}
        </div>
      </div>
    </section>
  )
}
