export const LIST_PAGE_SIZE = 20;

/** Clamp stale/invalid page numbers after filtering, without changing list order. */
export function paginateList<T>(items: readonly T[], requested?: string) {
  const total = items.length;
  const pages = Math.max(1, Math.ceil(total / LIST_PAGE_SIZE));
  const parsed = Number(requested);
  const page = Number.isSafeInteger(parsed) && parsed > 0 ? Math.min(parsed, pages) : 1;
  const offset = (page - 1) * LIST_PAGE_SIZE;
  return {items: items.slice(offset, offset + LIST_PAGE_SIZE), total, pages, page, start: total ? offset + 1 : 0, end: Math.min(offset + LIST_PAGE_SIZE, total)};
}
