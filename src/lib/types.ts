export type AppRole = "tutor" | "student";
export type PriorityLevel = "High" | "Med" | "Low";
export type TaskType = "Theory" | "Topical" | "Quiz" | "Yearly";
export type TaskStatus = "Not Started" | "In Progress" | "Done";

export type Profile = {
  id: string;
  full_name: string | null;
  role: AppRole;
  created_at: string;
};

export type Subject = {
  id: string;
  name: string;
  caie_code: string;
  total_chapters: number;
};

export type Chapter = {
  id: string;
  subject_id: string;
  name: string;
  syllabus_code: string | null;
  sort_order: number;
  priority_level: PriorityLevel;
};

export type Task = {
  id: string;
  chapter_id: string;
  task_type: TaskType;
  status: TaskStatus;
  confidence_score: number | null;
  next_review_date: string | null;
};

export type MistakeLog = {
  id: string;
  chapter_id: string;
  paper_reference: string | null;
  mistake_description: string;
  correct_concept: string;
  created_at: string;
};

export type SubjectProgress = {
  subject_id: string;
  subject_name: string;
  caie_code: string;
  total_tasks: number;
  completed_tasks: number;
  percent_complete: number | null;
};

export type SpacedRepetitionItem = {
  task_id: string;
  subject_name: string;
  chapter_name: string;
  priority_level: PriorityLevel;
  task_type: TaskType;
  confidence_score: number | null;
  next_review_date: string;
  status: TaskStatus;
};

export type BottleneckChapter = {
  chapter_id: string;
  subject_name: string;
  chapter_name: string;
  priority_level: PriorityLevel;
  avg_confidence: number | null;
  mistake_count: number;
};

export type HeatmapCell = {
  chapter_id: string;
  chapter_name: string;
  subject_name: string;
  subject_id: string;
  sort_order: number;
  latest_confidence: number | null;
};
