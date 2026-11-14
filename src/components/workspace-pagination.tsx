import Link from "next/link";

export function WorkspacePagination({ label, previous, next }: {
  label: string;
  previous?: string;
  next?: string;
}) {
  if (!previous && !next) return null;

  return <nav className="actions pagination" aria-label={label}>
    {previous ? <Link className="button menu-link-gold" href={previous}>Previous</Link>
      : <button className="gold" type="button" disabled>Previous</button>}
    {next ? <Link className="button menu-link-gold" href={next}>Next</Link>
      : <button className="gold" type="button" disabled>Next</button>}
  </nav>;
}
