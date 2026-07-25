import { Hero } from "@/components/hero";
import { FeatureShowcase } from "@/components/feature-showcase";
import { TextToSpeech } from "@/components/text-to-speech";
import { TeacherMode } from "@/components/teacher-mode";
import { HowItWorks } from "@/components/how-it-works";
import { CTA } from "@/components/cta";
import { Footer } from "@/components/footer";
import { Providers } from "@/components/providers";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Rishi — A better way to read, listen, and learn",
  description:
    "Rishi is launching soon on iPhone: a thoughtful way to read, listen, and learn with your books.",
  openGraph: {
    title: "Rishi — A better way to read, listen, and learn",
    description:
      "Rishi is launching soon on iPhone. Explore a more thoughtful reading experience.",
    images: ["/brand/rishi-icon.png"],
  },
  icons: { icon: "/brand/rishi-icon.png" },
};

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
