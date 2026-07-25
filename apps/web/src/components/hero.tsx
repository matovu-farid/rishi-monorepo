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
          A better way to read, listen, and learn
        </h1>

        <p className="text-lg md:text-xl text-muted-foreground text-balance max-w-2xl mx-auto leading-relaxed">
          Rishi is launching soon on iPhone. Bring your books into a more thoughtful,
          flexible experience designed for the Apple ecosystem, with more platforms to come.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 pt-8">
          <a href="#features" className="px-8 py-3 rounded-full bg-foreground text-background hover:opacity-90 transition">
            Explore the experience
          </a>
        </div>
      </div>
    </section>
  );
}
