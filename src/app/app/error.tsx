"use client";
export default function ErrorPage({ reset }: { reset: () => void }) {
  return (
    <section className="panel">
      <h1>Could not load this section</h1>
      <p>
        Check the connection, migrations, and your account access. No
        placeholder data will be shown.
      </p>
      <button onClick={reset}>Reintentar</button>
    </section>
  );
}
