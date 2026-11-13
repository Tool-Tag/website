import { Badge, Panel } from "./ui";
import { denverDateTime } from "@/lib/domain/time";

type DatedEntry = { label: string; at: string };

export function CustomerTrackingDetails({ total, finished, cancelled, currentPiece, milestones }: {
  total: number;
  finished: number;
  cancelled: number;
  currentPiece?: number;
  milestones: DatedEntry[];
}) {
  const hasExactPieceStatuses = finished === total || cancelled === total || (finished === 0 && cancelled === 0);
  return <>
    <Panel title="Your pieces">
      {total > 0 ? <>
        <p className="muted">{`${finished}/${total} ${total === 1 ? "piece" : "pieces"} finished`}</p>
        <ul className="tracking-piece-list">
          {Array.from({ length: total }, (_, index) => {
            const piece = index + 1;
            const status = piece === currentPiece ? "In progress" : !hasExactPieceStatuses
              ? "Individual status unavailable"
              : finished === total ? "Finished" : cancelled === total ? "Cancelled" : "Pending";
            return <li key={piece}><strong>Piece {piece}</strong><Badge>{status}</Badge></li>;
          })}
        </ul>
      </> : <p className="muted">No pieces recorded yet.</p>}
    </Panel>
    <Panel title="Step history">
      {milestones.length ? <ol className="tracking-dated-list">{milestones.map(entry =>
        <li key={entry.label}><strong>{entry.label}</strong><time dateTime={entry.at}>{denverDateTime(entry.at)}</time></li>
      )}</ol> : <p className="muted">No dated milestones are available yet.</p>}
    </Panel>
    <Panel title="Updates sent to you">
      <p className="muted">Sent-message history is unavailable on this tracking link.</p>
    </Panel>
  </>;
}
