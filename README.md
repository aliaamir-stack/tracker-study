# CAIE O-Level Progress Tracker

A full-stack revision and progress tracking platform for Cambridge CAIE O-Level students and tutors.

### Built For
- **Mathematics (Syllabus D) 4024**
- **Chemistry 5070**
- **Physics 5054**
- **Computer Science 2210**

---

## Key Features

- **Dual-Role Dashboard (Tutor & Student)**: Role-based routing and permissions via Supabase Auth & RLS.
- **Full Syllabus Browser**: Hierarchical view across all 4 subjects, 166 chapters, and 664 individual task milestones (Theory, Topical, Quiz, Yearly).
- **Spaced Repetition & Daily Hitlist Engine**:
  - Automatically schedules review intervals based on confidence ratings (1–2: 3 days, 3: 7 days, 4–5: 21 days).
  - Surfaces overdue review items with dedicated tags.
- **Red Pen Mistake Bank**: Log exam question errors, marking scheme fixes, and search past mistakes by paper reference or keyword.
- **Tutor Command Center**:
  - Macro progress statistics per subject.
  - Bottleneck alerts for low-confidence or high-priority topics.
  - Spaced repetition queue controls to reassign review intervals or mark tasks done.

---

## Tech Stack

- **Framework**: Next.js 16 (App Router, Turbopack, Server Actions)
- **Database & Auth**: Supabase (PostgreSQL with RLS & Triggers)
- **Styling**: Tailwind CSS & Lucide Icons
- **TypeScript**: Strict type safety

---

## Getting Started

### 1. Clone & Install
```bash
git clone https://github.com/aliaamir-stack/tracker-study.git
cd tracker-study
npm install
```

### 2. Configure Environment Variables
Copy `.env.local.example` to `.env.local`:
```env
NEXT_PUBLIC_SUPABASE_URL=your-project-url
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
```

### 3. Database Setup
Run the SQL schema in `supabase/schema.sql` inside your Supabase project's SQL Editor.

### 4. Run Locally
```bash
npm run dev
```
Open [http://localhost:3000](http://localhost:3000) in your browser.
