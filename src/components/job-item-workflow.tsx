import {EvidenceCapture} from "@/components/evidence-capture";
import { EvidenceGallery } from "@/components/evidence-gallery";
import { Form } from "@/components/form";
import { WorkPreparation } from "@/components/work-preparation";
import { Panel } from "@/components/ui";
import type { QuoteItem } from "@/lib/domain/quote-items";

type JobItem = {
  id: string;
  sequence: number;
  article: string;
  stage: "Preparation" | "Engraving" | "Finished Evidence" | "Finished" | "Cancelled";
  scope_snapshot: QuoteItem;
};

type EvidenceFile = {
  id: string;
  type: string;
  file_name?: string;
  job_item_id?: string | null;
  [key: string]: unknown;
};

export function JobItemWorkflow({
  jobId,
  items,
  files,
  role,
  pickupReturn,
}: {
  jobId: string;
  jobCode: string;
  items: JobItem[];
  files: EvidenceFile[];
  role: string;
  pickupReturn: boolean;
}) {
  const ordered = [...items].sort((a, b) => a.sequence - b.sequence);
  const total = ordered.length;
  const finished = ordered.filter((item) => item.stage === "Finished").length;
  const current = ordered.find(
    (item) => !["Finished", "Cancelled"].includes(item.stage),
  );

  if (!total) {
    return (
      <Panel title="Production">
        <p className="muted">No production items are registered for this Job.</p>
      </Panel>
    );
  }

  const progress = (
    <p className="muted">
      <strong>{finished}/{total}</strong> items completed
    </p>
  );

  if (!current) {
    return (
      <>
        <Panel title="Production complete">
          {progress}
          <p>All approved items have finished evidence and are marked Finished.</p>
          {pickupReturn && (
            <p className="notice success">
              The Job is ready to continue through the Return flow in Pick &amp; Return.
            </p>
          )}
        </Panel>

        {!pickupReturn && role === "admin" && (
          <Form
            operation="complete-production"
            hidden={{ id: jobId }}
            fields={[]}
            back={`/app/jobs/${jobId}`}
            button="Finished"
          />
        )}
      </>
    );
  }

  const itemFiles = files.filter(
    (file) =>
      ["Finished Evidence","Production Evidence"].includes(file.type) && file.job_item_id === current.id,
  );

  const scope = {
    ...(current.scope_snapshot ?? {}),
    quantity: 1,
    article: current.article,
  } as QuoteItem;

  return (
    <>
      <Panel title={`Item ${current.sequence} of ${total} · ${current.article}`}>
        {progress}

        {current.stage === "Preparation" && (
          <>
            <p className="muted">
              Review the approved scope for this item before engraving.
            </p>
            <WorkPreparation items={[scope]} />
            {role === "admin" && (
              <Form
                operation="job-item"
                hidden={{ id: current.id, action: "next" }}
                fields={[]}
                back={`/app/jobs/${jobId}`}
                button="Next"
              />
            )}
          </>
        )}

        {["Engraving", "Finished Evidence"].includes(current.stage) && (
          <>
            <p className="muted">
              Engraving is active for this item. Add finished evidence before marking it Finished.
            </p>
            <WorkPreparation items={[scope]} />

            <div className="work-notes">
              <small>Finished evidence</small>
              <EvidenceGallery files={itemFiles} />
            </div>

            {role === "admin" && current.stage === "Engraving" && (
              <EvidenceCapture config={{jobId,jobItemId:current.id,type:"Production Evidence",defaultVisibility:"customer"}} />
            )}

            {role === "admin" &&
              current.stage === "Finished Evidence" &&
              itemFiles.length > 0 && (
                <Form
                  operation="job-item"
                  hidden={{ id: current.id, action: "finished" }}
                  fields={[]}
                  back={`/app/jobs/${jobId}`}
                  button="Finished"
                />
              )}
          </>
        )}
      </Panel>

      {ordered
        .filter((item) => item.stage === "Finished")
        .map((item) => (
          <p className="muted" key={item.id}>
            ✓ Item {item.sequence}: {item.article}
          </p>
        ))}
    </>
  );
}
