import { type Metadata } from "next";
import {
  ClerkProvider,
  SignInButton,
  SignUpButton,
  SignedIn,
  SignedOut,
  UserButton,
} from "@clerk/nextjs";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { Header } from "@/components/header";
import { Button } from "@/components/ui/button";

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
  // border-b flex px-2  border-border bg-background/80 backdrop-blur-sm sticky top-0 z-50
  return (
    <ClerkProvider>
      <html lang="en">
        <body
          className={`${geistSans.variable} ${geistMono.variable} antialiased`}
        >
          <header className="flex justify-end bg-background/80 border-b   items-center p-4 gap-4 h-16 sticky top-0 z-100 ">
            <Header />
            <SignedOut>
              <SignInButton>
                <Button className="bg-[#542beb] h-8  text-white whitespace-nowrap rounded-full font-medium text-sm sm:text-base  sm:h-12 px-4 sm:px-5 cursor-pointer">
                  Sign In
                </Button>
              </SignInButton>
              <SignUpButton>
                <Button className="bg-[#542beb] h-8  text-white whitespace-nowrap rounded-full font-medium text-sm sm:text-base  sm:h-12 px-4 sm:px-5 cursor-pointer">
                  Sign Up
                </Button>
              </SignUpButton>
            </SignedOut>
            <SignedIn>
              <UserButton />
            </SignedIn>
          </header>

          {children}
        </body>
      </html>
    </ClerkProvider>
  );
}
