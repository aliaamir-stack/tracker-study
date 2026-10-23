"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { CheckCircle2, Circle, RotateCcw } from "lucide-react";
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
import type { TaskStatus, TaskType } from "@/lib/types";

export type HitlistTask = {
  id: string;
  task_type: TaskType;
  status: TaskStatus;
  confidence_score: number | null;
  chapter_name: string;
  subject_name: string;
  priority_level: string;
  is_review_due?: boolean;
};

export function DailyHitlist({ tasks }: { tasks: HitlistTask[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [scores, setScores] = useState<Record<string, number>>({});
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  function showMessage(msg: string, isError = false) {
    if (isError) {
      setError(msg);
      setSuccess(null);
    } else {
      setSuccess(msg);
      setError(null);
    }
    setTimeout(() => {
      setError(null);
      setSuccess(null);
    }, 3000);
  }

  async function markDone(taskId: string, chapterName: string) {
    const score = scores[taskId] ?? 3;
    const supabase = createClient();
    const { error } = await supabase
      .from("tasks")
      .update({
        status: "Done",
        confidence_score: score,
      })
      .eq("id", taskId);

    if (error) {
      showMessage(error.message, true);
      return;
    }

    showMessage(`✓ "${chapterName}" marked done (confidence ${score}/5)`);
    startTransition(() => router.refresh());
  }

  async function undoTask(taskId: string, chapterName: string) {
    const supabase = createClient();
    const { error } = await supabase
      .from("tasks")
      .update({
        status: "Not Started",
        confidence_score: null,
      })
      .eq("id", taskId);

    if (error) {
      showMessage(error.message, true);
      return;
    }

    showMessage(`↩ "${chapterName}" reverted to Not Started`);
    startTransition(() => router.refresh());
  }

  return (
    <Card className="border-slate-200 shadow-sm">
      <CardHeader>
        <CardTitle>Daily hitlist</CardTitle>
        <CardDescription>
          Just today&apos;s focus — finish these, then stop.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {(error || success) && (
          <div
            className={`mb-4 rounded-lg px-3 py-2 text-sm ${
              error
                ? "bg-red-50 text-red-800 border border-red-200"
                : "bg-emerald-50 text-emerald-800 border border-emerald-200"
            }`}
            role="alert"
          >
            {error ?? success}
          </div>
        )}
        {tasks.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            Nothing queued. Ask your tutor to set confidence scores or
            priorities.
          </p>
        ) : (
          <ul className="space-y-4">
            {tasks.map((task) => {
              const done = task.status === "Done";
              return (
                <li
                  key={task.id}
                  className="rounded-xl border border-slate-200 bg-white p-4"
                >
                  <div className="flex items-start gap-3">
                    {done ? (
                      <CheckCircle2 className="mt-0.5 size-5 shrink-0 text-emerald-600" />
                    ) : (
                      <Circle className="mt-0.5 size-5 shrink-0 text-slate-300" />
                    )}
                    <div className="min-w-0 flex-1 space-y-3">
                      <div>
                        <div className="flex items-center gap-2">
                          <p
                            className={`font-medium ${done ? "text-slate-400 line-through" : "text-slate-900"}`}
                          >
                            {task.chapter_name}
                          </p>
                          {task.is_review_due && (
                            <Badge
                              variant="secondary"
                              className="bg-blue-100 text-blue-700 border-blue-200 text-[10px]"
                            >
                              <RotateCcw className="size-3 mr-1" />
                              Review Due
                            </Badge>
                          )}
                        </div>
                        <p className="text-sm text-slate-500">
                          {task.subject_name} · {task.task_type} ·{" "}
                          {task.priority_level}
                        </p>
                      </div>
                      {!done ? (
                        <div className="flex flex-wrap items-center gap-3">
                          <label className="text-xs font-medium text-slate-600">
                            Confidence
                            <select
                              className="ml-2 rounded-md border border-slate-200 bg-white px-2 py-1 text-sm"
                              value={scores[task.id] ?? 3}
                              onChange={(e) =>
                                setScores((prev) => ({
                                  ...prev,
                                  [task.id]: Number(e.target.value),
                                }))
                              }
                            >
                              {[1, 2, 3, 4, 5].map((n) => (
                                <option key={n} value={n}>
                                  {n}
                                </option>
                              ))}
                            </select>
                          </label>
                          <Button
                            size="sm"
                            disabled={pending}
                            onClick={() =>
                              markDone(task.id, task.chapter_name)
                            }
                          >
                            Mark done
                          </Button>
                        </div>
                      ) : (
                        <Button
                          variant="ghost"
                          size="sm"
                          disabled={pending}
                          onClick={() =>
                            undoTask(task.id, task.chapter_name)
                          }
                          className="text-xs text-slate-500 hover:text-slate-700"
                        >
                          <RotateCcw className="size-3 mr-1" />
                          Undo
                        </Button>
                      )}
                    </div>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
