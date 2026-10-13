import { requirePermission } from "@/lib/domain/context";
import { can } from "@/lib/auth/permissions";
import { Heading, FinanceTabs } from "@/components/ui";
import { RefundsPanel } from "@/features/refunds";
export const dynamic = "force-dynamic";
export default async function Page() { const { access } = await requirePermission("payments.refund", "payments.view"); return <><Heading title="Refunds" subtitle="Manual refunds, payment proof and auditable confirmations."/><FinanceTabs includeGeneral={can(access, "payments.view")}/><RefundsPanel /></>; }
