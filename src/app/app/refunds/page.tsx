import {Heading} from "@/components/ui";
import {RefundsPanel} from "@/features/refunds";
export const dynamic="force-dynamic";
export default function Page() {
 return <><Heading title="Refunds" subtitle="Review, approve and track refund cases through completion."/><RefundsPanel/></>;
}
