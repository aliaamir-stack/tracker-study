"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Search, Trash2, CheckCircle2 } from "lucide-react";
import type { MistakeLog } from "@/lib/types";
import { deleteMistakeAction } from "@/app/actions/mistakes";

type ChapterOption = {
  id: string;
  name: string;
  subject_name: string;
};

type MistakeRow = MistakeLog & {
  chapter_name: string;
  subject_name: string;
};

export function MistakeLogger({
  chapters,
  mistakes,
}: {
  chapters: ChapterOption[];
  mistakes: MistakeRow[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [chapterId, setChapterId] = useState(chapters[0]?.id ?? "");
  const [paper, setPaper] = useState("");
  const [description, setDescription] = useState("");
  const [concept, setConcept] = useState("");
  const [filterSubject, setFilterSubject] = useState("all");
  const [searchQuery, setSearchQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const subjects = useMemo(
    () => Array.from(new Set(chapters.map((c) => c.subject_name))).sort(),
    [chapters],
  );

  const filtered = mistakes.filter((m) => {
    const matchesSubject =
      filterSubject === "all" || m.subject_name === filterSubject;
    const q = searchQuery.toLowerCase().trim();
    const matchesSearch =
      !q ||
      m.mistake_description.toLowerCase().includes(q) ||
      m.correct_concept.toLowerCase().includes(q) ||
      m.chapter_name.toLowerCase().includes(q) ||
      (m.paper_reference ?? "").toLowerCase().includes(q);
    return matchesSubject && matchesSearch;
  });

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

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (!chapterId || !description.trim() || !concept.trim()) {
      showMessage("Chapter, mistake, and correct concept are required.", true);
      return;
    }

    const supabase = createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    const { error: insertError } = await supabase.from("mistake_log").insert({
      chapter_id: chapterId,
      paper_reference: paper.trim() || null,
      mistake_description: description.trim(),
      correct_concept: concept.trim(),
      created_by: user?.id ?? null,
    });

    if (insertError) {
      showMessage(insertError.message, true);
      return;
    }

    setPaper("");
    setDescription("");
    setConcept("");
    showMessage("✓ Mistake logged successfully");
    startTransition(() => router.refresh());
  }

  async function deleteMistake(id: string) {
    const res = await deleteMistakeAction(id);

    if (!res.success) {
      showMessage(res.error || "Failed to remove mistake", true);
      return;
    }

    showMessage("✓ Mistake removed");
    startTransition(() => router.refresh());
  }

  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <Card>
        <CardHeader>
          <CardTitle>Red pen logger</CardTitle>
          <CardDescription>
            Capture the mistake and the marking-scheme fix while it&apos;s
            fresh.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={onSubmit} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="chapter">Chapter</Label>
              <select
                id="chapter"
                className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 text-sm"
                value={chapterId}
                onChange={(e) => setChapterId(e.target.value)}
              >
                {chapters.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.subject_name} — {c.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <Label htmlFor="paper">Paper reference</Label>
              <Input
                id="paper"
                placeholder="e.g. MJ24 P2 Q4b"
                value={paper}
                onChange={(e) => setPaper(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="mistake">What went wrong</Label>
              <Textarea
                id="mistake"
                required
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                rows={3}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="concept">Correct concept / MS logic</Label>
              <Textarea
                id="concept"
                required
                value={concept}
                onChange={(e) => setConcept(e.target.value)}
                rows={3}
              />
            </div>
            {(error || success) && (
              <div
                className={`rounded-lg px-3 py-2 text-sm ${
                  error
                    ? "bg-red-50 text-red-800 border border-red-200"
                    : "bg-emerald-50 text-emerald-800 border border-emerald-200"
                }`}
                role="alert"
              >
                {error ?? success}
              </div>
            )}
            <Button type="submit" disabled={pending || chapters.length === 0}>
              {pending ? "Saving…" : "Log mistake"}
            </Button>
          </form>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Mistake bank</CardTitle>
          <CardDescription>
            {mistakes.length} logged · Filter and revise before exams.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex flex-col gap-2 sm:flex-row">
            <select
              className="flex h-9 rounded-md border border-input bg-transparent px-3 text-sm sm:w-48"
              value={filterSubject}
              onChange={(e) => setFilterSubject(e.target.value)}
            >
              <option value="all">All subjects</option>
              {subjects.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
            <div className="relative flex-1">
              <Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
              <Input
                placeholder="Search mistakes…"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                className="pl-9"
              />
            </div>
          </div>

          {filtered.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {mistakes.length === 0
                ? "No mistakes logged yet."
                : "No matches found."}
            </p>
          ) : (
            <ul className="max-h-[28rem] space-y-3 overflow-y-auto pr-1">
              {filtered.map((m) => (
                <li
                  key={m.id}
                  className="group rounded-lg border border-slate-200 bg-slate-50/80 p-3"
                >
                  <div className="flex items-start justify-between gap-2">
                    <p className="text-xs font-medium tracking-wide text-slate-500 uppercase">
                      {m.subject_name} · {m.chapter_name}
                      {m.paper_reference ? ` · ${m.paper_reference}` : ""}
                    </p>
                    <Button
                      variant="ghost"
                      size="sm"
                      disabled={pending}
                      onClick={() => deleteMistake(m.id)}
                      className="h-6 w-6 p-0 opacity-0 group-hover:opacity-100 transition-opacity text-slate-400 hover:text-red-600"
                      title="Delete mistake"
                    >
                      <Trash2 className="size-3.5" />
                    </Button>
                  </div>
                  <p className="mt-1 text-sm text-slate-800">
                    <span className="font-medium text-red-700">Mistake: </span>
                    {m.mistake_description}
                  </p>
                  <p className="mt-1 text-sm text-slate-800">
                    <span className="font-medium text-emerald-700">Fix: </span>
                    {m.correct_concept}
                  </p>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
