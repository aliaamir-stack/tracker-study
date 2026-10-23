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
import { Input } from "@/components/ui/input";
import {
  CheckCircle2,
  Circle,
  Loader2,
  Search,
  ChevronDown,
  ChevronRight,
} from "lucide-react";
import type { TaskType, TaskStatus, PriorityLevel } from "@/lib/types";

export type SyllabusTask = {
  id: string;
  task_type: TaskType;
  status: TaskStatus;
  confidence_score: number | null;
};

export type SyllabusChapter = {
  id: string;
  name: string;
  syllabus_code: string | null;
  sort_order: number;
  priority_level: PriorityLevel;
  tasks: SyllabusTask[];
};

export type SyllabusSubject = {
  id: string;
  name: string;
  caie_code: string;
  total_chapters: number;
  chapters: SyllabusChapter[];
};

const STATUS_ICON: Record<TaskStatus, React.ReactNode> = {
  Done: <CheckCircle2 className="size-4 text-emerald-600" />,
  "In Progress": <Loader2 className="size-4 text-blue-500" />,
  "Not Started": <Circle className="size-4 text-slate-300" />,
};

const STATUS_CYCLE: TaskStatus[] = ["Not Started", "In Progress", "Done"];

const PRIORITY_COLORS: Record<PriorityLevel, string> = {
  High: "bg-red-100 text-red-700 border-red-200",
  Med: "bg-amber-100 text-amber-700 border-amber-200",
  Low: "bg-slate-100 text-slate-600 border-slate-200",
};

function confidenceLabel(score: number | null) {
  if (score == null) return "—";
  return `${score}/5`;
}

function confidenceColor(score: number | null) {
  if (score == null) return "text-slate-400";
  if (score <= 2) return "text-red-600";
  if (score === 3) return "text-amber-600";
  return "text-emerald-600";
}

export function SyllabusBrowser({
  subjects,
  canEdit,
}: {
  subjects: SyllabusSubject[];
  canEdit: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [search, setSearch] = useState("");
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});

  const toggleSubject = (id: string) =>
    setExpanded((prev) => ({ ...prev, [id]: !prev[id] }));

  async function cycleStatus(task: SyllabusTask) {
    const idx = STATUS_CYCLE.indexOf(task.status);
    const next = STATUS_CYCLE[(idx + 1) % STATUS_CYCLE.length];
    const supabase = createClient();

    const update: Record<string, unknown> = { status: next };
    if (next === "Done" && task.confidence_score == null) {
      update.confidence_score = 3;
    }

    const { error } = await supabase
      .from("tasks")
      .update(update)
      .eq("id", task.id);

    if (error) {
      alert(error.message);
      return;
    }
    startTransition(() => router.refresh());
  }

  async function setConfidence(taskId: string, score: number) {
    const supabase = createClient();
    const { error } = await supabase
      .from("tasks")
      .update({ confidence_score: score })
      .eq("id", taskId);

    if (error) {
      alert(error.message);
      return;
    }
    startTransition(() => router.refresh());
  }

  const q = search.toLowerCase().trim();

  return (
    <Card>
      <CardHeader>
        <CardTitle>Syllabus browser</CardTitle>
        <CardDescription>
          All chapters across {subjects.length} subjects · Click status icons to
          cycle · Click confidence to change
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="relative">
          <Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
          <Input
            placeholder="Search chapters…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9"
          />
        </div>

        <div className="space-y-3">
          {subjects.map((subject) => {
            const isOpen = expanded[subject.id] ?? false;
            const filtered = q
              ? subject.chapters.filter(
                  (ch) =>
                    ch.name.toLowerCase().includes(q) ||
                    (ch.syllabus_code ?? "").toLowerCase().includes(q),
                )
              : subject.chapters;

            if (q && filtered.length === 0) return null;

            const completedTasks = subject.chapters.reduce(
              (sum, ch) =>
                sum + ch.tasks.filter((t) => t.status === "Done").length,
              0,
            );
            const totalTasks = subject.chapters.reduce(
              (sum, ch) => sum + ch.tasks.length,
              0,
            );
            const pct =
              totalTasks > 0
                ? Math.round((completedTasks / totalTasks) * 100)
                : 0;

            return (
              <div
                key={subject.id}
                className="rounded-xl border border-slate-200 bg-white overflow-hidden"
              >
                <button
                  type="button"
                  onClick={() => toggleSubject(subject.id)}
                  className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left hover:bg-slate-50/80 transition-colors"
                >
                  <div className="flex items-center gap-3 min-w-0">
                    {isOpen || (q && filtered.length > 0) ? (
                      <ChevronDown className="size-4 shrink-0 text-slate-400" />
                    ) : (
                      <ChevronRight className="size-4 shrink-0 text-slate-400" />
                    )}
                    <div className="min-w-0">
                      <p className="font-semibold text-slate-900">
                        {subject.name}
                      </p>
                      <p className="text-xs text-slate-500">
                        CAIE {subject.caie_code} · {subject.chapters.length}{" "}
                        chapters
                      </p>
                    </div>
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <span className="text-sm tabular-nums text-slate-600">
                      {completedTasks}/{totalTasks}
                    </span>
                    <div className="h-2 w-20 rounded-full bg-slate-100 overflow-hidden">
                      <div
                        className="h-full rounded-full bg-emerald-500 transition-all"
                        style={{ width: `${pct}%` }}
                      />
                    </div>
                    <span className="text-xs tabular-nums text-slate-500 w-8 text-right">
                      {pct}%
                    </span>
                  </div>
                </button>

                {(isOpen || (q && filtered.length > 0)) && (
                  <div className="border-t border-slate-100">
                    <div className="grid grid-cols-[1fr_repeat(4,_72px)_80px] gap-0 px-4 py-2 text-[11px] font-medium tracking-wide text-slate-500 uppercase border-b border-slate-100">
                      <span>Chapter</span>
                      <span className="text-center">Theory</span>
                      <span className="text-center">Topical</span>
                      <span className="text-center">Quiz</span>
                      <span className="text-center">Yearly</span>
                      <span className="text-center">Conf.</span>
                    </div>
                    <ul className="divide-y divide-slate-50 max-h-[400px] overflow-y-auto">
                      {filtered
                        .slice()
                        .sort((a, b) => a.sort_order - b.sort_order)
                        .map((chapter) => {
                          const tasksByType = new Map(
                            chapter.tasks.map((t) => [t.task_type, t]),
                          );

                          const avgConfidence = (() => {
                            const scored = chapter.tasks.filter(
                              (t) => t.confidence_score != null,
                            );
                            if (scored.length === 0) return null;
                            return (
                              scored.reduce(
                                (s, t) => s + (t.confidence_score ?? 0),
                                0,
                              ) / scored.length
                            );
                          })();

                          return (
                            <li
                              key={chapter.id}
                              className="grid grid-cols-[1fr_repeat(4,_72px)_80px] gap-0 px-4 py-2.5 items-center hover:bg-slate-50/60 transition-colors"
                            >
                              <div className="min-w-0 flex items-center gap-2">
                                <Badge
                                  variant="outline"
                                  className={`shrink-0 text-[10px] px-1.5 py-0 ${PRIORITY_COLORS[chapter.priority_level]}`}
                                >
                                  {chapter.priority_level}
                                </Badge>
                                <span className="text-sm text-slate-800 truncate">
                                  {chapter.name}
                                </span>
                              </div>

                              {(
                                [
                                  "Theory",
                                  "Topical",
                                  "Quiz",
                                  "Yearly",
                                ] as TaskType[]
                              ).map((type) => {
                                const task = tasksByType.get(type);
                                if (!task) {
                                  return (
                                    <span
                                      key={type}
                                      className="flex justify-center"
                                    >
                                      <Circle className="size-4 text-slate-200" />
                                    </span>
                                  );
                                }
                                return (
                                  <button
                                    key={type}
                                    type="button"
                                    disabled={pending}
                                    onClick={() => cycleStatus(task)}
                                    className="flex justify-center hover:scale-125 transition-transform disabled:opacity-50"
                                    title={`${type}: ${task.status}`}
                                  >
                                    {STATUS_ICON[task.status]}
                                  </button>
                                );
                              })}

                              <div className="flex justify-center">
                                {canEdit ? (
                                  <select
                                    className={`w-14 text-center text-xs font-medium rounded border border-slate-200 bg-transparent py-0.5 ${confidenceColor(avgConfidence !== null ? Math.round(avgConfidence) : null)}`}
                                    value={
                                      chapter.tasks.find(
                                        (t) => t.confidence_score != null,
                                      )?.confidence_score ?? ""
                                    }
                                    onChange={(e) => {
                                      const score = Number(e.target.value);
                                      chapter.tasks.forEach((t) =>
                                        setConfidence(t.id, score),
                                      );
                                    }}
                                  >
                                    <option value="">—</option>
                                    {[1, 2, 3, 4, 5].map((n) => (
                                      <option key={n} value={n}>
                                        {n}/5
                                      </option>
                                    ))}
                                  </select>
                                ) : (
                                  <span
                                    className={`text-xs font-medium ${confidenceColor(avgConfidence !== null ? Math.round(avgConfidence) : null)}`}
                                  >
                                    {avgConfidence !== null
                                      ? `${avgConfidence.toFixed(1)}/5`
                                      : "—"}
                                  </span>
                                )}
                              </div>
                            </li>
                          );
                        })}
                    </ul>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </CardContent>
    </Card>
  );
}
