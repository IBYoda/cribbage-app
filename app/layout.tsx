import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { AppearanceProvider } from "@/components/AppearanceProvider";
import { APPEARANCE_INLINE_SCRIPT } from "@/lib/appearance";
import { displayFont } from "@/lib/fonts";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Nobs!",
  description:
    "Shared Deck, Separate Rooms. Cribbage for friends on a call: one shared deck, and everyone's hand stays private.",
  // A private game for friends: keep it out of search engines.
  robots: { index: false, follow: false },
};

// viewport-fit=cover lets the page extend under a notch / home indicator, so
// the table shell can pad itself with env(safe-area-inset-*) instead of the
// browser letterboxing it. Width and scale are Next's defaults, restated.
export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    // suppressHydrationWarning: the inline script below may add an attribute
    // to <html> before React hydrates (see the Next guide "Preventing flash
    // before hydration"); the DOM wins.
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} ${displayFont.variable} h-full antialiased`}
      suppressHydrationWarning
    >
      <head>
        {/* This device's cached table surface, on <html> before the first
            paint, so the table page's Loading screen is already the right
            colour on a refresh (lib/appearance.ts). Can't throw. */}
        <script dangerouslySetInnerHTML={{ __html: APPEARANCE_INLINE_SCRIPT }} />
      </head>
      <body className="min-h-full flex flex-col">
        {/* The signed-in player's own card back and table surface. */}
        <AppearanceProvider>{children}</AppearanceProvider>
      </body>
    </html>
  );
}
