/**
 * Shared server-side helpers for CMS routes (form parsing, Postgres array I/O).
 * Copied from the shipped per-app CMSes.
 */

/** Checkbox / string → boolean. Unchecked checkboxes are simply absent. */
export function parseBool(v: unknown): boolean {
  return v === "on" || v === "true" || v === true;
}

/** Read a string form field safely. */
export function formStr(form: Record<string, unknown>, key: string): string {
  const v = form[key];
  return typeof v === "string" ? v.trim() : "";
}

/** Read a possibly-repeated form field as a string list. */
export function formList(form: Record<string, unknown>, key: string): string[] {
  const v = form[key];
  if (Array.isArray(v)) return v.filter((x): x is string => typeof x === "string");
  if (typeof v === "string" && v !== "") return [v];
  return [];
}

/**
 * Build a Postgres text[] literal (e.g. {"a b",c}) for binding with an explicit
 * `::text[]` / `::uuid[]` cast — the connection uses fetch_types:false
 * (Hyperdrive), which disables postgres.js array type inference.
 */
export function toPgTextArray(items: string[]): string {
  if (items.length === 0) return "{}";
  const esc = items.map((t) => `"${t.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`);
  return `{${esc.join(",")}}`;
}

/**
 * Normalize a free-text category into the R2 key segment. Lowercased; spaces
 * collapse to "-"; only [a-z0-9_-] survive. Returns null when nothing usable
 * remains (for Arul a category is REQUIRED — it is the key partition and the
 * browse axis).
 */
export function categorySlug(category: unknown): string | null {
  if (typeof category !== "string") return null;
  const slug = category
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9_-]/g, "");
  return slug.length > 0 && slug.length <= 64 ? slug : null;
}
