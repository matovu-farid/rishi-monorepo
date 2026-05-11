import { Hero } from "@/components/hero";
import { FeatureShowcase } from "@/components/feature-showcase";
import { TextToSpeech } from "@/components/text-to-speech";
import { TeacherMode } from "@/components/teacher-mode";
import { HowItWorks } from "@/components/how-it-works";
import { CTA } from "@/components/cta";
import { Footer } from "@/components/footer";
import { Providers } from "@/components/providers";


export default function Home() {
  return (
    <Providers>
      <main className="min-h-screen bg-background text-foreground">
        <Hero />
        <FeatureShowcase />
        <TextToSpeech />
        <TeacherMode />
        <HowItWorks />
        <CTA />
        <Footer />
      </main>
    </Providers>
  );
}
