import { ArrowRight } from 'lucide-react'

export function Hero() {
  return (
    <section className="relative overflow-hidden pt-20 pb-32 px-6 md:pt-32 md:pb-48">
      {/* Subtle gradient background */}
      <div className="absolute inset-0 -z-10">
        <div className="absolute top-20 right-0 w-96 h-96 bg-amber-500/10 rounded-full blur-3xl"></div>
        <div className="absolute bottom-0 left-0 w-96 h-96 bg-orange-500/10 rounded-full blur-3xl"></div>
      </div>

      <div className="max-w-4xl mx-auto text-center space-y-6">
        <h1 className="text-5xl md:text-7xl font-bold text-balance leading-tight">
          Reading that adapts to <span className="bg-gradient-to-r from-amber-500 to-orange-500 bg-clip-text text-transparent">you</span>
        </h1>
        
        <p className="text-lg md:text-xl text-muted-foreground text-balance max-w-2xl mx-auto leading-relaxed">
          Imagine a reading experience where books become interactive teachers. Rishi transforms how you engage with knowledge through natural conversation and the freedom to listen at your own pace.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 pt-8">
          <button className="px-8 py-3 rounded-full bg-accent text-accent-foreground font-medium hover:opacity-90 transition flex items-center gap-2">
            Get Started
            <ArrowRight size={20} />
          </button>
          <button className="px-8 py-3 rounded-full border border-border text-foreground hover:bg-muted transition">
            Watch Demo
          </button>
        </div>
      </div>
    </section>
  )
}
