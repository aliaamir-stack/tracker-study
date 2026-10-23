import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import type { HeatmapCell } from "@/lib/types";

function cellColor(score: number | null) {
  if (score == null) return "bg-slate-100 text-slate-400";
  if (score <= 2) return "bg-red-500/90 text-white";
  if (score === 3) return "bg-amber-400 text-slate-900";
  return "bg-emerald-500/90 text-white";
}

export function ConfidenceHeatmap({ cells }: { cells: HeatmapCell[] }) {
  const bySubject = cells.reduce<Record<string, HeatmapCell[]>>((acc, cell) => {
    const key = cell.subject_name;
    if (!acc[key]) acc[key] = [];
    acc[key].push(cell);
    return acc;
  }, {});

  return (
    <Card>
      <CardHeader>
        <CardTitle>Confidence heatmap</CardTitle>
        <CardDescription>
          Red ≤ 2 · Yellow = 3 · Green ≥ 4 · Grey = not scored yet
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        {Object.keys(bySubject).length === 0 ? (
          <p className="text-sm text-muted-foreground">No chapters loaded.</p>
        ) : (
          Object.entries(bySubject).map(([subject, list]) => (
            <div key={subject} className="space-y-2">
              <h3 className="text-sm font-semibold text-slate-800">{subject}</h3>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
                {list
                  .slice()
                  .sort((a, b) => a.sort_order - b.sort_order)
                  .map((cell) => (
                    <div
                      key={cell.chapter_id}
                      title={`${cell.chapter_name}: ${cell.latest_confidence ?? "unscored"}`}
                      className={`rounded-md px-2 py-2 text-[11px] leading-tight ${cellColor(cell.latest_confidence)}`}
                    >
                      <span className="line-clamp-2">{cell.chapter_name}</span>
                    </div>
                  ))}
              </div>
            </div>
          ))
        )}
      </CardContent>
    </Card>
  );
}
