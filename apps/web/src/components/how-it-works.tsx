import { BookOpen, Ear, MessageSquare } from 'lucide-react'

export function HowItWorks() {
  return (
    <section id="howitworks" className="py-20 px-6 md:py-32">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-16">
          <h2 className="text-4xl md:text-5xl font-bold mb-4">Three simple steps</h2>
          <p className="text-lg text-muted-foreground text-pretty">
            Getting started is effortless. No complicated setup, no learning curve.
          </p>
        </div>

        <div className="grid md:grid-cols-3 gap-8">
          {[
            {
              icon: BookOpen,
              step: '1',
              title: 'Add Your Books',
              desc: 'Import books from your library or open files directly. Your collection is organized and ready to go.'
            },
            {
              icon: Ear,
              step: '2',
              title: 'Read or Listen',
              desc: 'Read at your own pace, or listen while you do other things. Switch between modes whenever you want.'
            },
            {
              icon: MessageSquare,
              step: '3',
              title: 'Ask & Learn',
              desc: 'When something interests you or confuses you, ask your book. Get instant clarity and deeper insights.'
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
