"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { TABLE_CODE_LENGTH, cleanTableCodeInput, tableCodeError } from "@/lib/tableCode";

// JOIN A TABLE, right on the home screen: the 4-digit code and a Join button.
// The same rules as the Join page (lib/tableCode.ts) and the same result:
// straight to /tables/<code>, where the table page does the actual join.
// Enter submits (it's a form); phones get the number pad (inputMode).
export function JoinTableForm() {
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
    router.push(`/tables/${code}`);
  }

  return (
    <form onSubmit={handleSubmit} noValidate className="flex flex-col gap-1">
      <div className="flex gap-2">
        <label htmlFor="home-table-code" className="sr-only">
          Table code
        </label>
        <input
          id="home-table-code"
          type="text"
          inputMode="numeric"
          autoComplete="off"
          maxLength={TABLE_CODE_LENGTH}
          placeholder="Code"
          value={code}
          onChange={(e) => {
            setCode(cleanTableCodeInput(e.target.value));
            setError(null);
          }}
          aria-invalid={error ? true : undefined}
          aria-describedby="home-table-code-error"
          className="felt-input felt-input--code w-0 flex-1"
        />
        <button type="submit" className="peg-btn peg-btn--ghost shrink-0">
          Join a Table
        </button>
      </div>
      {/* Space kept for the message, so showing it moves nothing. */}
      <p id="home-table-code-error" role="alert" className="min-h-5 text-sm text-[var(--error-on-felt)]">
        {error}
      </p>
    </form>
  );
}
