import { useEffect, useState } from "react";
import { supabase } from "./supabase";

export type GroupEvent = {
  id: string;
  group_id: string;
  type: string;
  payload: Record<string, any>;
  created_at: string;
};

/** Subscribe to events + messages for a group; returns the latest N events. */
export function useGroupLedgerTape(groupId: string | undefined, limit = 40) {
  const [events, setEvents] = useState<GroupEvent[]>([]);

  useEffect(() => {
    if (!groupId) return;
    let cancelled = false;

    (async () => {
      const { data } = await supabase
        .from("events")
        .select("*")
        .eq("group_id", groupId)
        .order("created_at", { ascending: false })
        .limit(limit);
      if (!cancelled && data) setEvents(data as GroupEvent[]);
    })();

    const ch = supabase
      .channel(`events:${groupId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "events",
          filter: `group_id=eq.${groupId}`,
        },
        (payload) => {
          setEvents((prev) => [payload.new as GroupEvent, ...prev].slice(0, limit));
        },
      )
      .subscribe();

    return () => {
      cancelled = true;
      supabase.removeChannel(ch);
    };
  }, [groupId, limit]);

  return events;
}
