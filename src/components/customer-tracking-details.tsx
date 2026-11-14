import { Badge, Panel } from "./ui";
import { denverDateTime } from "@/lib/domain/time";

type DatedEntry = { label: string; at: string };

export type TrackingHistory = {
  pieces: { sequence: number; name: string; stage: string }[];
  steps: DatedEntry[];
  updates: { event: string; at: string }[];
};

export function CustomerTrackingDetails({ total, finished, milestones, history }: {
  total: number;
  finished: number;
  milestones: DatedEntry[];
  history: TrackingHistory | null;
}) {
  const steps = history?.steps ?? milestones;
  return <>
    <Panel title="Your pieces">
      {total > 0 && <p className="muted">{`${finished}/${total} ${total === 1 ? "piece" : "pieces"} finished`}</p>}
      {history?.pieces.length ? <ul className="tracking-piece-list">
        {history.pieces.map(piece => <li key={piece.sequence}>
          <strong>{piece.name}</strong><Badge>{piece.stage}</Badge>
        </li>)}
      </ul> : <p className="muted">{history ? "No pieces recorded yet." : "Piece details are temporarily unavailable."}</p>}
    </Panel>
    <Panel title="Step history">
      {steps.length ? <ol className="tracking-dated-list">{steps.map((entry, index) =>
        <li key={index}><strong>{entry.label}</strong><time dateTime={entry.at}>{denverDateTime(entry.at)}</time></li>
      )}</ol> : <p className="muted">No dated milestones are available yet.</p>}
    </Panel>
    <Panel title="Updates sent to you">
      {history?.updates.length ? <ul className="tracking-dated-list">{history.updates.map((entry, index) =>
        <li key={index}><strong>{entry.event}</strong><time dateTime={entry.at}>{denverDateTime(entry.at)}</time></li>
      )}</ul> : <p className="muted">{history ? "No sent updates yet." : "Sent updates are temporarily unavailable."}</p>}
    </Panel>
  </>;
}
