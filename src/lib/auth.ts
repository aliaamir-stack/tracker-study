import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { AppRole, Profile } from "@/lib/types";

export async function getSessionUser() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return { supabase, user };
}

export async function requireProfile(expectedRole?: AppRole) {
  const { supabase, user } = await getSessionUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile, error } = await supabase
    .from("profiles")
    .select("id, full_name, role, created_at")
    .eq("id", user.id)
    .single();

  if (error || !profile) {
    redirect("/login");
  }

  const typed = profile as Profile;

  if (expectedRole && typed.role !== expectedRole) {
    redirect(typed.role === "tutor" ? "/tutor" : "/student");
  }

  return { profile: typed, supabase };
}
