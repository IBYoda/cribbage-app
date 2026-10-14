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
// follows the device as on a plain page. The Profile page needs it: its
// Appearance preview and swatches must look exactly as they always have
// (Classic follows the device), and data-scheme="dark" on an ancestor would
// force them dark.
export function CardRoomFrame({
  title,
  children,
  after,
  backHome = true,
  followDeviceScheme = false,
}: {
  title?: string;
  children: ReactNode;
  after?: ReactNode;
  backHome?: boolean;
  followDeviceScheme?: boolean;
}) {
  return (
    <div className="card-room" data-scheme={followDeviceScheme ? undefined : "dark"}>
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col items-center justify-center gap-6 px-5 py-8">
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
