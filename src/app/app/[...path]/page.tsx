export const maxDuration = 300;
import { notFound } from "next/navigation";
import { isConfigured } from "@/lib/supabase/server";
import { Heading, Panel } from "@/components/ui";
import { Customers } from "@/features/customers";
import { Quotes } from "@/features/quotes";
import { Jobs } from "@/features/jobs";
import { Finance } from "@/features/finance";
import { Equipment } from "@/features/equipment";
import { Settings } from "@/features/settings";
import { FinanceHub } from "@/features/finance-hub";
export default async function AppPage({
  params,
  searchParams,
}: {
  params: Promise<{ path: string[] }>;
  searchParams: Promise<Record<string, string>>;
}) {
  const { path } = await params;
  const q = await searchParams;
  if (
    ![
      "customers",
      "quotes",
      "jobs",
      "finance",
      "equipment",
      "settings",
      "finance-hub",
    ].includes(path[0])
  )
    notFound();
  if (!isConfigured())
    return (
      <>
        <Heading title={path[0]} />
        <Panel>
          Connect Supabase and apply the migrations to activate this section.
        </Panel>
      </>
    );
  switch (path[0]) {
    case "customers":
      return <Customers id={path[1]} q={q.q} />;
    case "quotes":
      return <Quotes id={path[1]} customer={q.customer} revise={q.revise} />;
    case "jobs":
      return <Jobs id={path[1]} />;
    case "equipment":
      return <Equipment expense={q.expense} />;
    case "finance":
      return path[1] === "equipment" ? (
        <Equipment expense={q.expense} />
      ) : (
        <Finance section={path[1]} id={path[2]} created={q.created} />
      );
    case "settings":
      return <Settings />;
    case "finance-hub":
      return <FinanceHub />;
    default:
      notFound();
  }
}
