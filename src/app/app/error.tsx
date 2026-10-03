"use client";
export default function ErrorPage({ reset }: { reset: () => void }) {
  return (
    <section className="panel">
      <h1>No se pudo cargar esta sección</h1>
      <p>
        Comprueba la conexión, las migraciones y el acceso de tu cuenta. No se
        mostrarán datos inventados.
      </p>
      <button onClick={reset}>Reintentar</button>
    </section>
  );
}
