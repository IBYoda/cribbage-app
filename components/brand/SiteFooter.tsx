import { AboutDialog } from "@/components/brand/AboutDialog";

// The rules we point to: Bicycle's cribbage page (checked: it loads, and it
// covers his nobs and muggins).
export const RULES_URL = "https://bicyclecards.com/how-to-play/cribbage";

// A cribbage peg, in brass: the separator between footer links.
export function PegDot() {
  return <span className="peg-dot" aria-hidden="true" />;
}

// A tiny fish, drawn for this app.
export function Fish() {
  return (
    <svg viewBox="0 0 32 16" width="22" height="11" aria-hidden="true" className="shrink-0">
      <path d="M2 8 C 7 1, 17 1, 23 8 C 17 15, 7 15, 2 8 Z M23 8 L30 3 L28 8 L30 13 Z" fill="currentColor" />
      <circle cx="8" cy="7" r="1.1" fill="#173b25" />
    </svg>
  );
}

// The card room's footer: About (a dialog) * Rules (new tab) * the contact
// "number", which is deliberately plain text and not a tel: link.
export function SiteFooter() {
  return (
    <footer className="site-footer">
      <AboutDialog />
      <PegDot />
      <a className="footer-link" href={RULES_URL} target="_blank" rel="noopener noreferrer">
        Rules
      </a>
      <PegDot />
      <span>Contact: 1-800-#SAND</span>
      <span className="text-[var(--brass)]">
        <Fish />
      </span>
    </footer>
  );
}
