import Link from "next/link";
import type { ReactNode } from "react";
import { Wordmark } from "@/components/brand/Wordmark";
import { SiteFooter } from "@/components/brand/SiteFooter";

// The card-room frame for the simple pages (Log In, Sign Up, Start a Table,
// Join a Table, Profile): the felt, the wordmark (a link home), the page's
// content in a panel, anything that follows it, an outlined "Back home"
// button, and the footer. Styling only -- each page keeps its own logic.
//
// followDeviceScheme: leave off data-scheme="dark", so the dark: variant
// follows the device as on a plain page. No real page passes it any more:
// the Profile page used it until Green Felt became the default surface
// (October 31, 2026), and has drawn its frame dark like the other pages
// since. Only a dev mock (app/dev) still sets it.
export function CardRoomFrame({
  title,
  children,
  after,
  backHome = true,
  followDeviceScheme = false,
  compact = false,
  wide = false,
  edgeToEdge = false,
}: {
  title?: string;
  children: ReactNode;
  after?: ReactNode;
  backHome?: boolean;
  followDeviceScheme?: boolean;
  // Tighter spacing around the panel (16px gaps, 12px top and bottom), for
  // the taller pages -- Start a Table, the opponent chooser -- so they fit a
  // phone screen without scrolling. Off: exactly as before.
  compact?: boolean;
  // A wider page (768px instead of 448px), for the Hand Calculator's rows of
  // 13 cards on a big screen. Off: exactly as before.
  wide?: boolean;
  // On a phone, an 8px side margin instead of 20px, so the panel (and the
  // Hand Calculator's fan of 13 cards) gets as much of the width as it can.
  // From 640px up, the usual margin. Off: exactly as before.
  edgeToEdge?: boolean;
}) {
  return (
    <div className="card-room" data-scheme={followDeviceScheme ? undefined : "dark"}>
      <main
        className={`mx-auto flex w-full ${wide ? "max-w-3xl" : "max-w-md"} flex-1 flex-col items-center justify-center ${edgeToEdge ? "px-2 sm:px-5" : "px-5"} ${
          compact ? "gap-4 py-3" : "gap-6 py-8"
        }`}
      >
        <Link href="/" aria-label="Nobs! home" className="rounded-lg">
          <Wordmark size="small" />
        </Link>
        <section
          className="felt-panel flex w-full flex-col gap-4"
          aria-labelledby={title ? "page-title" : undefined}
        >
          {title && (
            <h1 id="page-title" className="font-display text-3xl font-bold italic">
              {title}
            </h1>
          )}
          {children}
        </section>
        {after}
        {backHome && (
          <Link href="/" className="peg-btn peg-btn--ghost w-full">
            Back home
          </Link>
        )}
      </main>
      <SiteFooter />
    </div>
  );
}
