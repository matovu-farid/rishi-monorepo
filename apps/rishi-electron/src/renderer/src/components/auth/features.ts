import { Volume2, MessageSquare, Mic, Sparkles, type LucideIcon } from "lucide-react";

export type PremiumFeature = "tts" | "chat" | "voice-input" | "ai-generic";

export interface PremiumFeatureConfig {
  icon: LucideIcon;
  title: string;
  description: string;
  bullets: string[];
}

export const PREMIUM_FEATURES: Record<PremiumFeature, PremiumFeatureConfig> = {
  tts: {
    icon: Volume2,
    title: "Listen to your books",
    description: "AI-powered text-to-speech turns any book into an audiobook.",
    bullets: [
      "Natural, expressive voices",
      "Reads EPUB, PDF, MOBI, and DjVu",
      "Remembers your spot across devices",
    ],
  },
  chat: {
    icon: MessageSquare,
    title: "Chat with your books",
    description:
      "Ask questions, get summaries, and explore ideas with an AI that knows your library.",
    bullets: [
      "Cites passages from the book you're reading",
      "Works across your entire library",
      "Remembers context within a conversation",
    ],
  },
  "voice-input": {
    icon: Mic,
    title: "Talk to your books",
    description: "Ask questions hands-free with realtime voice conversations.",
    bullets: [
      "Natural speech recognition",
      "Paired with AI book chat",
    ],
  },
  "ai-generic": {
    icon: Sparkles,
    title: "AI features require an account",
    description: "Sign in to unlock Rishi's AI-powered reading tools.",
    bullets: [],
  },
};
