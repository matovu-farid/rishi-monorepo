import { type Metadata } from "next";
import { Suspense } from "react";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { Header } from "@/components/header";
import { AuthButtons } from "@/components/auth-buttons";
import { DesktopHandoffListener } from "@/components/desktop-handoff-listener";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Rishi",
  description: "Rishi is a reading assistant that helps you read better.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        <Suspense fallback={null}>
          <DesktopHandoffListener />
        </Suspense>
        <header className="flex justify-end bg-background/80 border-b   items-center p-4 gap-4 h-16 sticky top-0 z-100 ">
          <Header />
          <AuthButtons />
        </header>

        {children}
      </body>
    </html>
  );
}
