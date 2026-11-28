import localFont from "next/font/local";

// ALL FONTS ARE SELF-HOSTED (lib/font-files/, each with its OFL.txt; credits
// in CREDITS.md): the build never fetches from Google -- that fetch failed
// Vercel builds.

// Geist and Geist Mono, exposed as --font-geist-sans / --font-geist-mono on
// <html> (app/layout.tsx) and mapped to Tailwind's --font-sans / --font-mono
// in app/globals.css. One variable latin file each (weights 100-900, from
// @fontsource-variable/geist and @fontsource-variable/geist-mono 5.3.0) --
// what next/font/google served before, and smaller than one file per weight.
// The default Arial-sized fallback matches next/font/google's.
export const geistSans = localFont({
  src: "./font-files/geist/geist-latin-wght-normal.woff2",
  weight: "100 900",
  style: "normal",
  variable: "--font-geist-sans",
  display: "swap",
});

export const geistMono = localFont({
  src: "./font-files/geist-mono/geist-mono-latin-wght-normal.woff2",
  weight: "100 900",
  style: "normal",
  variable: "--font-geist-mono",
  display: "swap",
});

// The display face for the "Nobs!" wordmark and the card-room headings ONLY
// (body text stays the app's own font). Exposed as --font-display on <html>
// (app/layout.tsx) and used through .font-display (app/globals.css, "CARD
// ROOM").
//
// Playfair Display's latin woff2 files are committed in
// lib/font-files/playfair-display/ (from @fontsource/playfair-display 5.3.0;
// SIL Open Font License, OFL.txt beside them and CREDITS.md), so the build
// never fetches from Google -- that fetch failed Vercel builds. Only the
// faces the app uses: 700 (headings, the tagline), 700 italic, and 900 italic
// (the wordmark, components/brand/Wordmark.tsx). The Times New Roman-sized
// fallback keeps the swap from moving the page, as next/font/google did for
// this serif face.
export const displayFont = localFont({
  src: [
    { path: "./font-files/playfair-display/playfair-display-latin-700-normal.woff2", weight: "700", style: "normal" },
    { path: "./font-files/playfair-display/playfair-display-latin-700-italic.woff2", weight: "700", style: "italic" },
    { path: "./font-files/playfair-display/playfair-display-latin-900-italic.woff2", weight: "900", style: "italic" },
  ],
  variable: "--font-display",
  display: "swap",
  fallback: ["serif"],
  adjustFontFallback: "Times New Roman",
});
