import Image from 'next/image'

export function FeatureShowcase() {
  return (
    <section id="features" className="py-20 px-6 md:py-32 bg-muted/30">
      <div className="max-w-7xl mx-auto">
        <div className="grid md:grid-cols-2 gap-12 items-center">
          {/* Left: Image */}
          <div className="relative grid grid-cols-2 gap-4 items-start">
            <div className="absolute inset-0 bg-gradient-to-br from-amber-500/20 to-orange-500/20 rounded-2xl blur-3xl -z-10"></div>
            <div className="border border-border rounded-2xl overflow-hidden bg-card h-full flex items-center justify-center p-4">
              <Image src="/screenshots/ios/library.png" alt="Rishi library on iPhone" width={1206} height={2622} className="w-full h-auto" />
            </div>
            <div className="border border-border rounded-2xl overflow-hidden bg-card flex items-center justify-center p-4 mt-12">
              <Image src="/screenshots/ios/library-books.png" alt="Rishi library with books on iPhone" width={1284} height={2778} className="w-full h-auto" />
            </div>
          </div>

          {/* Right: Features */}
          <div className="space-y-8">
            <div>
              <h2 className="text-4xl md:text-5xl font-bold mb-4">Your library, reimagined</h2>
              <p className="text-lg text-muted-foreground text-pretty leading-relaxed">
                Keep your books close and your reading life organized. Start with a library
                that feels at home on iPhone and grows with you across the Apple ecosystem.
              </p>
            </div>

            <div className="space-y-6">
              {[
                {
                  title: 'Seamless Sync',
                  desc: 'Your reading progress follows you everywhere'
                },
                {
                  title: 'Beautiful Rendering',
                  desc: 'Books display exactly as intended with perfect typography'
                },
                {
                  title: 'Fast & Responsive',
                  desc: 'Navigate through pages instantly, no lag, no loading'
                }
              ].map((feature, i) => (
                <div key={i} className="flex gap-4">
                  <div className="w-2 h-2 rounded-full bg-amber-500 mt-2 flex-shrink-0"></div>
                  <div>
                    <h3 className="font-semibold text-foreground">{feature.title}</h3>
                    <p className="text-sm text-muted-foreground">{feature.desc}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
