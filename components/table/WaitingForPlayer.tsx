"use client";

import { useEffect, useState } from "react";

// A host alone at the table: what they're waiting for, and the code to send
// a friend, big, with a Copy button. Sized for the middle region (see
// .waiting-stage in app/globals.css): stacked, or one row in a flat window.
export function WaitingForPlayer({ code }: { code: string }) {
  const [copyState, setCopyState] = useState<"idle" | "copied" | "failed">("idle");

  // The confirmation reverts after a moment.
  useEffect(() => {
    if (copyState === "idle") return;
    const t = window.setTimeout(() => setCopyState("idle"), 2000);
    return () => window.clearTimeout(t);
  }, [copyState]);

  async function handleCopy() {
    setCopyState((await copyText(code)) ? "copied" : "failed");
  }

  return (
    <div className="waiting-stage">
      <div className="flex flex-col items-center leading-tight">
        <p className="text-lg font-semibold">Waiting for a second player</p>
        <p className="text-sm text-zinc-500">Send them this table code:</p>
      </div>
      <div className="flex items-center gap-3">
        <span className="text-4xl font-bold leading-10 tracking-widest tabular-nums" aria-label={`Table code ${code}`}>
          {code}
        </span>
        <button
          onClick={handleCopy}
          className="min-h-10 min-w-[5.5rem] rounded border border-zinc-400 px-4 text-sm font-medium dark:border-zinc-600"
        >
          {copyState === "copied" ? "Copied!" : copyState === "failed" ? "Copy failed" : "Copy"}
        </button>
      </div>
    </div>
  );
}

// The Clipboard API only exists on secure origins (https, or localhost) -- a
// phone testing the dev server over the LAN by IP has none. The old
// execCommand route still works there.
async function copyText(text: string) {
  try {
    if (navigator.clipboard) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Fall through to the fallback.
  }
  try {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    return ok;
  } catch {
    return false;
  }
}
