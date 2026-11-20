"use client";

import { TableView } from "@/components/table/TableView";

// THE TABLE PAGE: a player's seat at a table. The table itself is
// components/table/TableView.tsx, shared with the watch page
// (app/watch/[code]/page.tsx), which draws it read-only for spectators.
export default function TablePage() {
  return <TableView />;
}
