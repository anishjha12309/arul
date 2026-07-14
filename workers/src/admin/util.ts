/**
 * Shared server-side helpers for CMS routes (form parsing, Postgres array I/O).
 */

/** Parse a comma-separated tags field into a trimmed, de-duped list. */
export function parseTags(csv: string | undefined): string[] {
  if (!csv) return [];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of csv.split(",")) {
    const t = raw.trim();
    if (t && !seen.has(t)) {
      seen.add(t);
      out.push(t);
    }
  }
  return out;
}

/**
 * Build a Postgres text[] literal (e.g. {"jumma mubarak",azaan}) for binding with
 * an explicit `::text[]` cast. We bind a literal string rather than a JS array
 * because the DB connection uses fetch_types:false (Hyperdrive), which disables
 * postgres.js array type inference.
 */
export function toPgTextArray(tags: string[]): string {
  if (tags.length === 0) return "{}";
  const esc = tags.map((t) => `"${t.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`);
  return `{${esc.join(",")}}`;
}

/**
 * Parse a Postgres text[] literal string (as returned with fetch_types:false)
 * back into a JS array — for displaying existing tags in edit forms.
 */
export function pgArrayToList(v: unknown): string[] {
  if (Array.isArray(v)) return v as string[];
  if (typeof v !== "string") return [];
  const s = v.trim();
  if (s === "" || s === "{}") return [];
  if (!s.startsWith("{") || !s.endsWith("}")) return [s];
  const inner = s.slice(1, -1);
  const out: string[] = [];
  let cur = "";
  let inQuotes = false;
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (ch === '"') {
      if (inQuotes && inner[i + 1] === '"') {
        cur += '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch === "\\" && inQuotes) {
      cur += inner[i + 1] ?? "";
      i++;
    } else if (ch === "," && !inQuotes) {
      out.push(cur);
      cur = "";
    } else {
      cur += ch;
    }
  }
  out.push(cur);
  return out.map((x) => x.trim()).filter((x) => x.length > 0);
}

/** Checkbox / string → boolean. Unchecked checkboxes are simply absent. */
export function parseBool(v: unknown): boolean {
  return v === "on" || v === "true" || v === true;
}

/** Read a string form field safely. */
export function formStr(form: Record<string, unknown>, key: string): string {
  const v = form[key];
  return typeof v === "string" ? v.trim() : "";
}

/** Parse a non-negative integer form field, or fall back. */
export function formInt(form: Record<string, unknown>, key: string, fallback = 0): number {
  const v = form[key];
  if (typeof v !== "string" || v.trim() === "") return fallback;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : fallback;
}
