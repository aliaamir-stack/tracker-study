"use client";

import { useState, useTransition } from "react";
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
import {
  AlertTriangle,
  ArrowUpDown,
  RotateCcw,
} from "lucide-react";
import type { BottleneckChapter, PriorityLevel } from "@/lib/types";

const PRIORITY_CYCLE: PriorityLevel[] = ["Low", "Med", "High"];

export function BottleneckAlerts({
  chapters,
}: {
  chapters: BottleneckChapter[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  async function cyclePriority(chapterId: string, current: PriorityLevel) {
    const idx = PRIORITY_CYCLE.indexOf(current);
    const next = PRIORITY_CYCLE[(idx + 1) % PRIORITY_CYCLE.length];
    const supabase = createClient();
    const { error } = await supabase
      .from("chapters")
      .update({ priority_level: next })
      .eq("id", chapterId);

    if (error) {
      alert(error.message);
      return;
    }
    startTransition(() => router.refresh());
  }

  async function resetReviewDates(chapterId: string) {
    const supabase = createClient();
    // Set next_review_date to now for all tasks in this chapter so they appear in queue
    const { error } = await supabase
      .from("tasks")
      .update({ next_review_date: new Date().toISOString() })
      .eq("chapter_id", chapterId);

    if (error) {
      alert(error.message);
      return;
    }
    startTransition(() => router.refresh());
  }

  return (
    <Card className="border-amber-200/80 bg-amber-50/40">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <AlertTriangle className="size-4 text-amber-600" />
          Bottleneck alerts
        </CardTitle>
        <CardDescription>
          Low average confidence (≤ 2.5) or ≥ 3 logged mistakes. Click priority
          to cycle · Reset pushes tasks back into the review queue.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {chapters.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No bottlenecks flagged yet.
          </p>
        ) : (
          <ul className="space-y-3">
            {chapters.map((c) => (
              <li
                key={c.chapter_id}
                className="rounded-lg border border-amber-200/70 bg-white/80 px-3 py-2"
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <p className="font-medium text-slate-900">
                      {c.chapter_name}
                    </p>
                    <p className="text-xs text-slate-500">{c.subject_name}</p>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant="outline">
                      avg {c.avg_confidence ?? "—"}
                    </Badge>
                    <Badge variant="secondary">
                      {c.mistake_count} mistakes
                    </Badge>
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={pending}
                      onClick={() =>
                        cyclePriority(c.chapter_id, c.priority_level)
                      }
                      title="Cycle priority: Low → Med → High"
                      className="h-7 gap-1 text-xs"
                    >
                      <ArrowUpDown className="size-3" />
                      {c.priority_level}
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={pending}
                      onClick={() => resetReviewDates(c.chapter_id)}
                      title="Push all tasks back into review queue"
                      className="h-7 gap-1 text-xs"
                    >
                      <RotateCcw className="size-3" />
                      Reset
                    </Button>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
