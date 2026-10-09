"use client";
export default function ErrorPage({ reset }: { reset: () => void }) {
  return (
    <section className="panel">
      <h1>This section could not be loaded</h1>
      <p>
        Check the connection, migrations, and your account access. No
        invented data will be shown.
      </p>
      <button onClick={reset}>Reintentar</button>
    </section>
  );
}
