import Image from 'next/image'

export function FeatureShowcase() {
  return (
    <section id="features" className="py-20 px-6 md:py-32 bg-muted/30">
      <div className="max-w-7xl mx-auto">
        <div className="grid md:grid-cols-2 gap-12 items-center">
          {/* Left: Image */}
          <div className="relative aspect-square md:aspect-auto">
            <div className="absolute inset-0 bg-gradient-to-br from-amber-500/20 to-orange-500/20 rounded-2xl blur-3xl -z-10"></div>
            <div className="border border-border rounded-2xl overflow-hidden bg-card h-full flex items-center justify-center p-4">
              <Image
                src="/screenshots/library.png"
                alt="Book library interface showing multiple books in a grid"
                width={500}
                height={400}
                className="w-full h-auto"
              />
            </div>
          </div>

          {/* Right: Features */}
          <div className="space-y-8">
            <div>
              <h2 className="text-4xl md:text-5xl font-bold mb-4">Your library, reimagined</h2>
              <p className="text-lg text-muted-foreground text-pretty leading-relaxed">
                Organize your books in one beautiful place. Access them instantly across all your devices, from desktop to tablet. Start reading one moment, pick up another the next.
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
