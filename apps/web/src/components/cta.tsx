import { ArrowRight } from "lucide-react";
import Link from "next/link";

export function CTA() {
  return (
    <section className="py-20 px-6 md:py-32 bg-gradient-to-br from-amber-500/10 to-orange-500/10">
      <div className="max-w-4xl mx-auto text-center space-y-8">
        <h2 className="text-4xl md:text-5xl font-bold text-balance">
          Your next chapter starts on iPhone.
        </h2>

        <p className="text-lg text-muted-foreground text-pretty max-w-2xl mx-auto leading-relaxed">
          iOS is launching soon, with macOS planned next. Join us for a reading
          experience that makes more room for curiosity.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4 pt-4">
          <Link href="/#features" className="px-8 py-3 rounded-full border border-border text-foreground hover:bg-muted transition flex items-center gap-2 w-full sm:w-auto justify-center">
            Explore the experience
            <ArrowRight size={20} />
          </Link>
        </div>

        <p className="text-sm text-muted-foreground pt-8">
          iOS launching soon · macOS planned next
        </p>
      </div>
    </section>
  );
}
