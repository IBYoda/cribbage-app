// "Nobs!" -- as in "one for his nobs". Brass on felt, in the display face. It
// is large text everywhere it appears, so brass on the felt (3.72:1)
// meets the 3:1 large-text contrast; small text on the felt uses cream.
export function Wordmark({ size = "hero" }: { size?: "hero" | "small" }) {
  const Tag = size === "hero" ? "h1" : "p";
  return (
    <Tag
      className={`wordmark font-display font-black italic tracking-tight ${
        size === "hero" ? "text-6xl sm:text-7xl" : "text-3xl"
      }`}
    >
      Nobs!
    </Tag>
  );
}
