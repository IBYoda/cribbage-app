"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { TABLE_CODE_LENGTH, cleanTableCodeInput, tableCodeError } from "@/lib/tableCode";

export default function JoinTablePage() {
  const router = useRouter();
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();

    const codeError = tableCodeError(code);
    if (codeError) {
      setError(codeError);
      return;
    }

    // The actual "join" (inserting into table_members) happens on the table
    // page itself, so revisiting this URL later re-confirms membership
    // instead of erroring on a duplicate join.
    router.push(`/tables/${code}`);
  }

  return (
    <CardRoomFrame title="Join a Table">
      <form onSubmit={handleSubmit} className="flex w-full flex-col gap-4">
        <div className="flex flex-col gap-1">
          <label htmlFor="code" className="text-sm font-medium">
            Table code
          </label>
          <input
            id="code"
            type="text"
            inputMode="numeric"
            pattern="[0-9]{4}"
            maxLength={TABLE_CODE_LENGTH}
            required
            value={code}
            onChange={(e) => setCode(cleanTableCodeInput(e.target.value))}
            aria-invalid={error ? true : undefined}
            aria-describedby={error ? "code-error" : undefined}
            className="felt-input felt-input--code"
          />
        </div>

        <button type="submit" className="peg-btn peg-btn--brass">
          Join
        </button>

        {error && (
          <p id="code-error" className="text-sm text-[var(--error-on-felt)]">
            {error}
          </p>
        )}
      </form>
    </CardRoomFrame>
  );
}
