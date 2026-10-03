"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
export function Nav({ bottom = false }: { bottom?: boolean }) {
  const path = usePathname();
  const links = bottom
    ? [
        ["finance-hub", "Finance Hub"],
        ["settings", "Configuración"],
      ]
    : [
        ["", "Dashboard"],
        ["quotes", "Cotizaciones"],
        ["jobs", "Trabajos"],
        ["customers", "Clientes"],
        ["finance", "Finanzas"],
        ["equipment", "Equipo"],
      ];
  return (
    <nav>
      {links.map(([p, n]) => (
        <Link
          key={p}
          href={`/app${p ? "/" + p : ""}`}
          aria-current={path === `/app${p ? "/" + p : ""}` ? "page" : undefined}
        >
          {n}
        </Link>
      ))}
    </nav>
  );
}
