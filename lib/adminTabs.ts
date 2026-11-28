// THE ADMIN PAGE'S TABS (app/admin/page.tsx): Tables, Reports, Kicks, in
// that order, opening on Tables. Each label carries how many items are
// loaded ("Reports (1)"); while a list is loading, or failed, just the name.
// Pure; tested by scripts/test-phase3.ts.

export type AdminTab = "tables" | "reports" | "kicks";

export const ADMIN_TABS: readonly { tab: AdminTab; name: string }[] = [
  { tab: "tables", name: "Tables" },
  { tab: "reports", name: "Reports" },
  { tab: "kicks", name: "Kicks" },
];

export const ADMIN_FIRST_TAB: AdminTab = "tables";

export function adminTabLabel(name: string, count: number | null): string {
  return count === null ? name : `${name} (${count})`;
}

// Arrow keys move between the tabs (wrapping), Home and End go to the ends;
// any other key: null.
export function adminTabAfterKey(current: AdminTab, key: string): AdminTab | null {
  const i = ADMIN_TABS.findIndex((t) => t.tab === current);
  const n = ADMIN_TABS.length;
  if (key === "ArrowRight") return ADMIN_TABS[(i + 1) % n].tab;
  if (key === "ArrowLeft") return ADMIN_TABS[(i - 1 + n) % n].tab;
  if (key === "Home") return ADMIN_TABS[0].tab;
  if (key === "End") return ADMIN_TABS[n - 1].tab;
  return null;
}
