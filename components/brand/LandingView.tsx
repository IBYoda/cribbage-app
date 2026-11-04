import Link from "next/link";
import { Wordmark } from "@/components/brand/Wordmark";
import { HeroHand } from "@/components/brand/HeroHand";
import { RotatingTagline } from "@/components/brand/RotatingTagline";
import { SiteFooter } from "@/components/brand/SiteFooter";

// THE LANDING PAGE (signed out). A card room: the felt, the "Nobs!" wordmark,
// the 29 hand in the top two thirds; Log In and Sign Up in the lower third,
// in thumb reach; the rotating tagline and the footer below them.
//
// signedOut: false while the session is still being read. The page is
// rendered the same either way -- so the first paint (and the server HTML,
// tagline included) is the card room -- but the buttons stay hidden (their
// space kept) until we know there's nobody signed in, so a signed-in player
// never sees "Log In" flash past on the way to their menu.
//
// linkExpired: an expired or already used email link brought them here -- a
// dismissible notice above the buttons, with its own Log in.
export function LandingView({
  signedOut,
  linkExpired = false,
  onDismissLinkExpired,
}: {
  signedOut: boolean;
  linkExpired?: boolean;
  onDismissLinkExpired?: () => void;
}) {
  return (
    <div className="card-room" data-scheme="dark">
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col px-5">
        <section className="flex flex-[2] flex-col items-center justify-center gap-3 pt-8 text-center">
          <Wordmark />
          <p className="text-base font-medium tracking-wide">Shared Deck, Separate Rooms</p>
          <div className="mt-6 w-full">
            <HeroHand />
          </div>
        </section>

        {/* The lower third, measured: the buttons start below two thirds of
            the screen height at 375x667, 390x844 and 1280x720. */}
        <section className="flex flex-1 flex-col justify-end gap-1 pt-6">
          {linkExpired && signedOut && (
            <div role="alert" className="felt-panel mb-2 flex flex-col gap-2 text-sm">
              <p>That link has expired or was already used. Log in to get a new one.</p>
              <div className="flex items-center justify-between gap-3">
                <Link href="/login" className="peg-btn peg-btn--brass peg-btn--small">
                  Log in
                </Link>
                <button type="button" onClick={onDismissLinkExpired} className="footer-link">
                  Dismiss
                </button>
              </div>
            </div>
          )}
          <div
            className={`flex flex-col gap-2.5 ${signedOut ? "" : "invisible"}`}
            aria-hidden={signedOut ? undefined : true}
          >
            <Link href="/login" className="peg-btn peg-btn--brass" tabIndex={signedOut ? undefined : -1}>
              Log In
            </Link>
            <Link href="/signup" className="peg-btn peg-btn--ghost" tabIndex={signedOut ? undefined : -1}>
              Sign Up
            </Link>
          </div>
          <RotatingTagline />
        </section>
      </main>
      <SiteFooter />
    </div>
  );
}
