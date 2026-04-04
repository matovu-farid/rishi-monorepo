import { Hero } from "@/components/hero";
import { FeatureShowcase } from "@/components/feature-showcase";
import { TextToSpeech } from "@/components/text-to-speech";
import { TeacherMode } from "@/components/teacher-mode";
import { HowItWorks } from "@/components/how-it-works";
import { CTA } from "@/components/cta";
import { Footer } from "@/components/footer";
import { Providers } from "@/components/providers";
import { ClerkListener } from "@/components/clerk-listener";
import { Suspense } from "react";


export default function Home() {
  return (
    <Providers>
      <Suspense fallback={<div></div>}>
        <ClerkListener />
      </Suspense>
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
