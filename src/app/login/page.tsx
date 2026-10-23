import { LoginForm } from "@/components/auth/login-form";
import { getSupabaseEnv } from "@/lib/env";

export default function LoginPage() {
  const ready = Boolean(getSupabaseEnv());

  return (
    <div className="flex flex-1 items-center justify-center bg-[radial-gradient(ellipse_at_top,_#eef4ff_0%,_#f8fafc_50%,_#f1f5f9_100%)] px-4 py-12">
      <div className="w-full max-w-md space-y-6 rounded-2xl border border-slate-200/80 bg-white/90 p-8 shadow-sm backdrop-blur">
        <div className="space-y-1 text-center">
          <p className="text-xs font-medium tracking-wide text-slate-500 uppercase">
            CAIE Progress Tracker
          </p>
          <h1 className="text-2xl font-semibold text-slate-900">Sign in</h1>
          <p className="text-sm text-slate-500">
            Tutor and student use the same login — role comes from your profile.
          </p>
        </div>
        {ready ? (
          <LoginForm />
        ) : (
          <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">
            Configure <code>.env.local</code> with your Supabase URL and anon key
            first.
          </p>
        )}
      </div>
    </div>
  );
}
