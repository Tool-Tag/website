"use client";
export default function ErrorPage({ reset }: { reset: () => void }) {
  return (
    <section className="panel">
      <h1>This Section Could Not Be Loaded</h1>
      <p>
        Check the connection, migrations, and your account access. No
        fabricated data will be shown.
      </p>
      <button onClick={reset}>Retry</button>
    </section>
  );
}
