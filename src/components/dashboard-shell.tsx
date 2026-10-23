import Link from "next/link";
import { SignOutButton } from "@/components/auth/sign-out-button";
import type { AppRole } from "@/lib/types";

type Props = {
  title: string;
  role: AppRole;
  displayName: string | null;
  children: React.ReactNode;
};

export function DashboardShell({ title, role, displayName, children }: Props) {
  return (
    <div className="min-h-full bg-[radial-gradient(ellipse_at_top,_#eef4ff_0%,_#f8fafc_45%,_#f1f5f9_100%)]">
      <header className="border-b border-slate-200/80 bg-white/70 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-3 sm:px-6">
          <div className="min-w-0">
            <p className="text-xs font-medium tracking-wide text-slate-500 uppercase">
              CAIE Progress Tracker
            </p>
            <h1 className="truncate text-lg font-semibold text-slate-900">
              {title}
            </h1>
          </div>
          <div className="flex items-center gap-2 sm:gap-3">
            <span className="hidden text-sm text-slate-600 sm:inline">
              {displayName ?? role}
            </span>
            <span className="rounded-md bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700 capitalize">
              {role}
            </span>
            <SignOutButton />
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl space-y-8 px-4 py-8 sm:px-6">
        {children}
      </main>
      <footer className="mx-auto max-w-6xl px-4 pb-8 text-center text-xs text-slate-400 sm:px-6">
        <Link href="/" className="hover:text-slate-600">
          Home
        </Link>
      </footer>
    </div>
  );
}
