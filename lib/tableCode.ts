// TABLE CODES: the 4-digit code a table is joined by. One set of rules for
// every place a code is typed (the Join page and the home page's Join field),
// so they can't drift apart.

export const TABLE_CODE_LENGTH = 4;

const TABLE_CODE_PATTERN = /^[0-9]{4}$/;

// What the field keeps as the player types: digits only, at most four.
export function cleanTableCodeInput(raw: string) {
  return raw.replace(/\D/g, "").slice(0, TABLE_CODE_LENGTH);
}

// null when the code is valid, otherwise the message to show.
export function tableCodeError(code: string): string | null {
  return TABLE_CODE_PATTERN.test(code) ? null : "Enter the 4-digit table code.";
}
