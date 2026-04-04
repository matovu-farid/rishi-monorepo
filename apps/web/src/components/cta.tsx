import { ArrowRight, Download } from 'lucide-react'

export function CTA() {
  return (
    <section className="py-20 px-6 md:py-32 bg-gradient-to-br from-amber-500/10 to-orange-500/10">
      <div className="max-w-4xl mx-auto text-center space-y-8">
        <h2 className="text-4xl md:text-5xl font-bold text-balance">
          Ready to transform your reading?
        </h2>

        <p className="text-lg text-muted-foreground text-pretty max-w-2xl mx-auto leading-relaxed">
          Rishi is available now. Download the app and start your first book today. Everything you need for a smarter, richer reading experience.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 pt-4">
          <button className="px-8 py-3 rounded-full bg-accent text-accent-foreground font-medium hover:opacity-90 transition flex items-center gap-2 w-full sm:w-auto justify-center">
            <Download size={20} />
            Download Now
          </button>
          <button className="px-8 py-3 rounded-full border border-border text-foreground hover:bg-muted transition flex items-center gap-2 w-full sm:w-auto justify-center">
            Learn More
            <ArrowRight size={20} />
          </button>
        </div>

        <p className="text-sm text-muted-foreground pt-8">
          Available for Mac, Windows, and Linux
        </p>
      </div>
    </section>
  )
}
