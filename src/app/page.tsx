import { redirect } from "next/navigation";
import Link from "next/link";
import { getSupabaseEnv } from "@/lib/env";
import { createClient } from "@/lib/supabase/server";
export const instant = false;

export default async function HomePage() {
  const env = getSupabaseEnv();

  if (!env) {
    return (
      <div className="flex flex-1 items-center justify-center bg-slate-50 px-4">
        <div className="max-w-lg space-y-4 rounded-2xl border border-slate-200 bg-white p-8 shadow-sm">
          <h1 className="text-2xl font-semibold text-slate-900">
            CAIE Progress Tracker
          </h1>
          <p className="text-slate-600">
            Add your Supabase keys to finish setup:
          </p>
          <ol className="list-decimal space-y-2 pl-5 text-sm text-slate-700">
            <li>
              Copy <code className="rounded bg-slate-100 px-1">.env.local.example</code>{" "}
              → <code className="rounded bg-slate-100 px-1">.env.local</code>
            </li>
            <li>
              Paste <strong>Project URL</strong> and <strong>anon key</strong> from
              Supabase → Settings → API
            </li>
            <li>
              Restart <code className="rounded bg-slate-100 px-1">npm run dev</code>
            </li>
          </ol>
        </div>
      </div>
    );
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("role")
    .eq("id", user.id)
    .single();

  if (profile?.role === "tutor") {
    redirect("/tutor");
  }
  if (profile?.role === "student") {
    redirect("/student");
  }

  return (
    <div className="flex flex-1 items-center justify-center px-4">
      <div className="max-w-md space-y-4 text-center">
        <h1 className="text-xl font-semibold">Profile role not set</h1>
        <p className="text-sm text-slate-600">
          Update <code>profiles.role</code> to <code>tutor</code> or{" "}
          <code>student</code> in the Supabase Table Editor.
        </p>
        <Link
          href="/login"
          className="inline-flex h-8 items-center justify-center rounded-lg bg-primary px-3 text-sm font-medium text-primary-foreground"
        >
          Back to login
        </Link>
      </div>
    </div>
  );
}
