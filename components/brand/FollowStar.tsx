"use client";

// THE FOLLOW STAR (PRD item 36, F2): top-right on every leaderboard card but
// your own. Outline when you don't follow that player, filled in brass when
// you do; a tap toggles it. A real toggle button: aria-pressed, a label that
// never changes ("Follow Big papi"), a tooltip ("Follow" / "Following") and a
// focus ring. Its box is 40 x 34 (.follow-star), so it stays clear of the
// "W - L" record line below; the card's name line keeps 28px free for it.
//
//   loading   the follow list isn't read yet: a dimmed, disabled outline
//   pending   its own call is in flight: disabled (FilteredLeaderboard flips
//             it at once and rolls it back if the server refuses)
export function FollowStar({
  name,
  following,
  loading,
  pending,
  onToggle,
}: {
  name: string;
  following: boolean;
  loading: boolean;
  pending: boolean;
  onToggle: () => void;
}) {
  return (
    <button
      type="button"
      className="follow-star"
      aria-pressed={following}
      aria-label={`Follow ${name}`}
      title={loading ? "Loading who you follow..." : following ? "Following" : "Follow"}
      disabled={loading || pending}
      data-loading={loading ? "" : undefined}
      onClick={onToggle}
    >
      <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">
        <path
          d="M12 2.8l2.76 5.6 6.18.9-4.47 4.36 1.05 6.15L12 16.9l-5.52 2.91 1.05-6.15L3.06 9.3l6.18-.9z"
          fill={following ? "currentColor" : "none"}
          stroke="currentColor"
          strokeWidth="1.8"
          strokeLinejoin="round"
        />
      </svg>
    </button>
  );
}
