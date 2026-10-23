"use server";

import { createClient as createServerClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";

export async function deleteMistakeAction(mistakeId: string): Promise<{ success: boolean; error?: string }> {
  try {
    const supabase = await createServerClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      return { success: false, error: "Not authenticated" };
    }

    const { data: profile } = await supabase
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single();

    const isTutor = profile?.role === "tutor";

    const admin = createAdminClient();

    // Check if mistake exists and whether user is creator or tutor
    const { data: mistake, error: fetchErr } = await admin
      .from("mistake_log")
      .select("id, created_by")
      .eq("id", mistakeId)
      .single();

    if (fetchErr || !mistake) {
      return { success: false, error: "Mistake not found" };
    }

    if (!isTutor && mistake.created_by && mistake.created_by !== user.id) {
      return { success: false, error: "You do not have permission to delete this mistake" };
    }

    const { error: delErr } = await admin
      .from("mistake_log")
      .delete()
      .eq("id", mistakeId);

    if (delErr) {
      return { success: false, error: delErr.message };
    }

    return { success: true };
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : "Failed to delete mistake",
    };
  }
}
