import Link from "next/link";
import type { ReactNode } from "react";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";

// The Log In and Sign Up pages' frame: the card-room frame, with a line plus
// an outlined button to the other page in place of "Back home". Styling only
// -- each page keeps its own fields, messages, redirects and auth calls.
export function AuthCard({
  title,
  children,
  switchPrompt,
  switchHref,
  switchLabel,
}: {
  title: string;
  children: ReactNode;
  switchPrompt: ReactNode;
  switchHref: string;
  switchLabel: string;
}) {
  return (
    <CardRoomFrame
      title={title}
      backHome={false}
      after={
        <div className="flex w-full flex-col items-center gap-2">
          <p className="text-sm">{switchPrompt}</p>
          <Link href={switchHref} className="peg-btn peg-btn--ghost w-full">
            {switchLabel}
          </Link>
        </div>
      }
    >
      {children}
    </CardRoomFrame>
  );
}
