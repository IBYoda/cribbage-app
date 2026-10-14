import { Playfair_Display } from "next/font/google";

// The display face for the "Nobs!" wordmark and the card-room headings ONLY
// (body text stays the app's own font). Self-hosted by next/font at build
// time; exposed as --font-display on <html> (app/layout.tsx) and used through
// .font-display (app/globals.css, "CARD ROOM").
export const displayFont = Playfair_Display({
  subsets: ["latin"],
  weight: ["700", "900"],
  style: ["normal", "italic"],
  variable: "--font-display",
  display: "swap",
});
