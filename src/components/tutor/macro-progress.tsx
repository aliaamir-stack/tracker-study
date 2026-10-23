import { Progress } from "@/components/ui/progress";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import type { SubjectProgress } from "@/lib/types";

export function MacroProgress({ subjects }: { subjects: SubjectProgress[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Macro progress</CardTitle>
        <CardDescription>
          Completed tasks vs total across all five papers (English deferred).
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        {subjects.length === 0 ? (
          <p className="text-sm text-muted-foreground">No subject data yet.</p>
        ) : (
          subjects.map((s) => {
            const pct = Number(s.percent_complete ?? 0);
            return (
              <div key={s.subject_id} className="space-y-2">
                <div className="flex items-baseline justify-between gap-3">
                  <div>
                    <p className="font-medium text-slate-900">{s.subject_name}</p>
                    <p className="text-xs text-slate-500">
                      CAIE {s.caie_code}
                    </p>
                  </div>
                  <p className="text-sm tabular-nums text-slate-600">
                    {s.completed_tasks}/{s.total_tasks} · {pct.toFixed(0)}%
                  </p>
                </div>
                <Progress value={pct} className="h-2" />
              </div>
            );
          })
        )}
      </CardContent>
    </Card>
  );
}
