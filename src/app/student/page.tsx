import { requireProfile } from "@/lib/auth";
import { DashboardShell } from "@/components/dashboard-shell";
import {
  DailyHitlist,
  type HitlistTask,
} from "@/components/student/daily-hitlist";
import { ConfidenceHeatmap } from "@/components/student/confidence-heatmap";
import { MistakeLogger } from "@/components/student/mistake-logger";
import {
  SyllabusBrowser,
  type SyllabusSubject,
} from "@/components/shared/syllabus-browser";
import type { HeatmapCell, MistakeLog } from "@/lib/types";

const HITLIST_SIZE = 5;

export const instant = false;

export default async function StudentPage() {
  const { profile, supabase } = await requireProfile("student");

  const todayIso = new Date().toISOString();

  const [
    dueTasksRes,
    fallbackTasksRes,
    chaptersRes,
    tasksRes,
    mistakesRes,
    syllabusRes,
  ] = await Promise.all([
    // Fix: include tasks with status "Done" that are overdue for review
    supabase
      .from("tasks")
      .select(
        `
        id,
        task_type,
        status,
        confidence_score,
        next_review_date,
        chapters!inner (
          name,
          priority_level,
          subjects!inner ( name )
        )
      `,
      )
      .lte("next_review_date", todayIso)
      .order("next_review_date", { ascending: true })
      .limit(HITLIST_SIZE),
    supabase
      .from("tasks")
      .select(
        `
        id,
        task_type,
        status,
        confidence_score,
        chapters!inner (
          name,
          priority_level,
          sort_order,
          subjects!inner ( name )
        )
      `,
      )
      .eq("status", "Not Started")
      .eq("task_type", "Theory")
      .order("created_at", { ascending: true })
      .limit(HITLIST_SIZE),
    supabase
      .from("chapters")
      .select(
        `
        id,
        name,
        sort_order,
        subject_id,
        subjects!inner ( id, name )
      `,
      )
      .order("sort_order"),
    supabase
      .from("tasks")
      .select("chapter_id, confidence_score, updated_at")
      .not("confidence_score", "is", null)
      .order("updated_at", { ascending: false }),
    supabase
      .from("mistake_log")
      .select(
        `
        id,
        chapter_id,
        paper_reference,
        mistake_description,
        correct_concept,
        created_at,
        chapters!inner (
          name,
          subjects!inner ( name )
        )
      `,
      )
      .order("created_at", { ascending: false })
      .limit(100),
    // Syllabus browser data
    supabase
      .from("subjects")
      .select(
        `
        id,
        name,
        caie_code,
        total_chapters,
        chapters (
          id,
          name,
          syllabus_code,
          sort_order,
          priority_level,
          tasks (
            id,
            task_type,
            status,
            confidence_score
          )
        )
      `,
      )
      .order("name"),
  ]);

  type NestedChapter = {
    name: string;
    priority_level: string;
    subjects: { name: string } | { name: string }[];
  };

  function subjectName(ch: NestedChapter) {
    const s = ch.subjects;
    return Array.isArray(s) ? s[0]?.name : s?.name;
  }

  const dueRaw = dueTasksRes.data ?? [];
  // Show overdue review tasks; if none, fall back to "Not Started" theory tasks
  const source = dueRaw.length > 0 ? dueRaw : (fallbackTasksRes.data ?? []);

  const hitlist: HitlistTask[] = source.map((row) => {
    const chapters = row.chapters as unknown as NestedChapter;
    const hasReviewDate =
      "next_review_date" in row && row.next_review_date != null;
    const isReviewDue = row.status === "Done" && hasReviewDate;
    return {
      id: row.id as string,
      task_type: row.task_type,
      status: isReviewDue ? ("In Progress" as const) : row.status,
      confidence_score: row.confidence_score,
      chapter_name: chapters.name,
      subject_name: subjectName(chapters) ?? "—",
      priority_level: chapters.priority_level,
      is_review_due: isReviewDue,
    };
  });

  const latestByChapter = new Map<string, number>();
  for (const t of tasksRes.data ?? []) {
    if (!latestByChapter.has(t.chapter_id)) {
      latestByChapter.set(t.chapter_id, t.confidence_score as number);
    }
  }

  const heatmap: HeatmapCell[] = (chaptersRes.data ?? []).map((ch) => {
    const subjects = ch.subjects as unknown as
      | { id: string; name: string }
      | { id: string; name: string }[];
    const subject = Array.isArray(subjects) ? subjects[0] : subjects;
    return {
      chapter_id: ch.id,
      chapter_name: ch.name,
      subject_name: subject?.name ?? "—",
      subject_id: subject?.id ?? ch.subject_id,
      sort_order: ch.sort_order,
      latest_confidence: latestByChapter.get(ch.id) ?? null,
    };
  });

  const chapterOptions = (chaptersRes.data ?? []).map((ch) => {
    const subjects = ch.subjects as unknown as
      | { name: string }
      | { name: string }[];
    const subject = Array.isArray(subjects) ? subjects[0] : subjects;
    return {
      id: ch.id,
      name: ch.name,
      subject_name: subject?.name ?? "—",
    };
  });

  const mistakes = (mistakesRes.data ?? []).map((m) => {
    const chapters = m.chapters as unknown as {
      name: string;
      subjects: { name: string } | { name: string }[];
    };
    const subjects = chapters.subjects;
    const subject = Array.isArray(subjects) ? subjects[0] : subjects;
    return {
      ...(m as MistakeLog),
      chapter_name: chapters.name,
      subject_name: subject?.name ?? "—",
    };
  });

  const syllabusSubjects = (syllabusRes.data ?? []) as unknown as SyllabusSubject[];

  return (
    <DashboardShell
      title="Student dashboard"
      role="student"
      displayName={profile.full_name}
    >
      <DailyHitlist tasks={hitlist} />
      <ConfidenceHeatmap cells={heatmap} />
      <SyllabusBrowser subjects={syllabusSubjects} canEdit={true} />
      <MistakeLogger chapters={chapterOptions} mistakes={mistakes} />
    </DashboardShell>
  );
}
