import Image from 'next/image'
import { Volume2 } from 'lucide-react'

export function TextToSpeech() {
  return (
    <section className="py-20 px-6 md:py-32">
      <div className="max-w-7xl mx-auto">
        <div className="grid md:grid-cols-2 gap-12 items-center">
          {/* Left: Content */}
          <div className="space-y-8 order-2 md:order-1">
            <div className="flex items-center gap-3">
              <Volume2 className="text-amber-500" size={32} />
              <span className="text-sm font-semibold text-amber-500 tracking-wide">FEATURE</span>
            </div>

            <div>
              <h2 className="text-4xl md:text-5xl font-bold mb-4">Listen while you live</h2>
              <p className="text-lg text-muted-foreground text-pretty leading-relaxed">
                Sometimes reading requires your eyes and hands. Go for a walk, do chores, or just relax while Rishi reads to you. Natural voices that sound human, not robotic. Adjust the speed to match your pace.
              </p>
            </div>

            <div className="space-y-4">
              {[
                'Perfect narration that understands punctuation and context',
                'Control playback with simple, intuitive controls',
                'Switch between reading and listening instantly'
              ].map((item, i) => (
                <div key={i} className="flex items-start gap-3">
                  <span className="text-amber-500 font-bold mt-0.5">✓</span>
                  <span className="text-muted-foreground">{item}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Right: Image */}
          <div className="relative order-1 md:order-2 aspect-square md:aspect-auto">
            <div className="absolute inset-0 bg-gradient-to-br from-amber-500/20 to-orange-500/20 rounded-2xl blur-3xl -z-10"></div>
            <div className="border border-border rounded-2xl overflow-hidden bg-card h-full flex items-center justify-center p-4">
              <Image
                src="/screenshots/book.png"
                alt="Reading interface with playback controls and dual-column layout"
                width={500}
                height={400}
                className="w-full h-auto"
              />
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
