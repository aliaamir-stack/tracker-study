"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { RotateCcw } from "lucide-react";
import type { SpacedRepetitionItem } from "@/lib/types";

function formatDate(iso: string) {
  return new Date(iso).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

export function SpacedRepetitionQueue({
  items,
}: {
  items: SpacedRepetitionItem[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  async function markForReview(taskId: string, newConfidence: number) {
    const supabase = createClient();
    // Setting confidence_score triggers the DB trigger which resets next_review_date
    const { error } = await supabase
      .from("tasks")
      .update({
        status: "In Progress",
        confidence_score: newConfidence,
      })
      .eq("id", taskId);

    if (error) {
      alert(error.message);
      return;
    }
    startTransition(() => router.refresh());
  }

  async function markDone(taskId: string) {
    const supabase = createClient();
    const { error } = await supabase
      .from("tasks")
      .update({ status: "Done" })
      .eq("id", taskId);

    if (error) {
      alert(error.message);
      return;
    }
    startTransition(() => router.refresh());
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Spaced repetition queue</CardTitle>
        <CardDescription>
          Tasks with <code className="text-xs">next_review_date ≤ today</code>.
          Reassign confidence to reschedule.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {items.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            Queue is clear — nothing due for review.
          </p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {items.map((item) => (
              <li
                key={item.task_id}
                className="flex flex-col gap-2 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="min-w-0">
                  <p className="truncate font-medium text-slate-900">
                    {item.chapter_name}
                  </p>
                  <p className="text-sm text-slate-500">
                    {item.subject_name} · {item.task_type}
                  </p>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <Badge variant="outline">{item.priority_level}</Badge>
                  <Badge
                    variant={
                      (item.confidence_score ?? 5) <= 2
                        ? "destructive"
                        : "secondary"
                    }
                  >
                    Conf {item.confidence_score ?? "—"}
                  </Badge>
                  <span className="text-xs tabular-nums text-slate-500">
                    due {formatDate(item.next_review_date)}
                  </span>
                  <select
                    className="h-7 rounded-md border border-slate-200 bg-white px-2 text-xs"
                    disabled={pending}
                    defaultValue=""
                    onChange={(e) => {
                      const val = e.target.value;
                      if (val) markForReview(item.task_id, Number(val));
                      e.target.value = "";
                    }}
                  >
                    <option value="" disabled>
                      Reassign…
                    </option>
                    {[1, 2, 3, 4, 5].map((n) => (
                      <option key={n} value={n}>
                        Conf → {n}
                      </option>
                    ))}
                  </select>
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={pending}
                    onClick={() => markDone(item.task_id)}
                    className="h-7 text-xs"
                  >
                    Done
                  </Button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
