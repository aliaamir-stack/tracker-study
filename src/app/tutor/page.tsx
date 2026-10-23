import { requireProfile } from "@/lib/auth";
import { DashboardShell } from "@/components/dashboard-shell";
import { MacroProgress } from "@/components/tutor/macro-progress";
import { SpacedRepetitionQueue } from "@/components/tutor/spaced-repetition-queue";
import { BottleneckAlerts } from "@/components/tutor/bottleneck-alerts";
import {
  SyllabusBrowser,
  type SyllabusSubject,
} from "@/components/shared/syllabus-browser";
import type {
  BottleneckChapter,
  SpacedRepetitionItem,
  SubjectProgress,
} from "@/lib/types";

export const instant = false;

export default async function TutorPage() {
  const { profile, supabase } = await requireProfile("tutor");

  const [progressRes, queueRes, bottleneckRes, syllabusRes] =
    await Promise.all([
      supabase.from("subject_progress").select("*").order("subject_name"),
      supabase.from("spaced_repetition_queue").select("*").limit(25),
      supabase.from("bottleneck_chapters").select("*").limit(20),
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

  const subjects = (progressRes.data ?? []) as SubjectProgress[];
  const queue = (queueRes.data ?? []) as SpacedRepetitionItem[];
  const bottlenecks = (bottleneckRes.data ?? []) as BottleneckChapter[];
  const syllabusSubjects = (syllabusRes.data ??
    []) as unknown as SyllabusSubject[];

  return (
    <DashboardShell
      title="Tutor dashboard"
      role="tutor"
      displayName={profile.full_name}
    >
      <div className="grid gap-6 lg:grid-cols-2">
        <MacroProgress subjects={subjects} />
        <BottleneckAlerts chapters={bottlenecks} />
      </div>
      <SpacedRepetitionQueue items={queue} />
      <SyllabusBrowser subjects={syllabusSubjects} canEdit={true} />
    </DashboardShell>
  );
}
