import Link from "next/link";
import { tableHref, type Refusal } from "@/lib/oneTable";

// A refusal from create_table, join_table_by_code, watch_table or
// create_computer_table (lib/oneTable.ts): its plain message, and for
// already_at_table a "Go to table NNNN" button straight to that table.
export function RefusalNotice({ refusal }: { refusal: Refusal }) {
  return (
    <div className="flex flex-col gap-2.5">
      <p className="text-sm text-[var(--error-on-felt)]" role="alert">
        {refusal.text}
      </p>
      {refusal.kind === "already_at_table" && (
        <Link href={tableHref(refusal.tableCode)} className="peg-btn peg-btn--brass">
          Go to table {refusal.tableCode}
        </Link>
      )}
    </div>
  );
}
