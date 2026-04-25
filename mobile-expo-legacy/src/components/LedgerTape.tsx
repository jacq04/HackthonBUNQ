import { useMemo } from "react";
import { ScrollView, Text, View } from "react-native";
import { GroupEvent } from "@/lib/realtime";

const ICONS: Record<string, string> = {
  "contribution.pending": "⋯",
  "contribution.posted": "✓",
  "contribution.voided": "✗",
  "payout.committed": "◈",
  "payout.ledger_only": "◇",
  "dispute.resolved": "⚖",
  "emergency.proposed": "!",
  "emergency.executed": "→",
  "collector.nudge_sent": "✉",
  "collector.escalated": "↗",
  "charter.finalized": "★",
  "payout.order_solved": "⇅",
};

export function LedgerTape({ events }: { events: GroupEvent[] }) {
  const formatted = useMemo(
    () => events.map((e) => ({ ...e, pretty: describe(e) })),
    [events],
  );

  return (
    <ScrollView className="flex-1" contentContainerClassName="py-2">
      {formatted.length === 0 && (
        <Text className="text-dusk/60 text-center py-6 italic">
          the tape starts empty — nothing has moved yet
        </Text>
      )}
      {formatted.map((e) => (
        <View
          key={e.id}
          className="flex-row items-center px-4 py-2 border-b border-soft/60"
        >
          <Text className="w-6 text-coral font-bold">{ICONS[e.type] ?? "·"}</Text>
          <View className="flex-1">
            <Text className="text-dusk">{e.pretty}</Text>
            <Text className="text-xs text-dusk/50">
              {new Date(e.created_at).toLocaleTimeString()}
            </Text>
          </View>
        </View>
      ))}
    </ScrollView>
  );
}

function describe(e: GroupEvent): string {
  const p = e.payload || {};
  switch (e.type) {
    case "contribution.pending":
      return `contribution pending — €${((p.amount_cents ?? 0) / 100).toFixed(2)}`;
    case "contribution.posted":
      return `contribution posted — €${((p.amount_cents ?? 0) / 100).toFixed(2)} · cycle ${p.cycle_month}`;
    case "payout.committed":
      return `payout committed — €${((p.amount_cents ?? 0) / 100).toFixed(2)}`;
    case "payout.ledger_only":
      return `payout on ledger — €${((p.amount_cents ?? 0) / 100).toFixed(2)} (bunq pending)`;
    case "dispute.resolved":
      return `dispute resolved — ${p.verdict}`;
    case "emergency.proposed":
      return `emergency exit proposed — refund €${((p.refund_cents ?? 0) / 100).toFixed(2)}`;
    case "emergency.executed":
      return `emergency exit executed — €${((p.refund_cents ?? 0) / 100).toFixed(2)} refunded`;
    case "collector.nudge_sent":
      return `collector nudge · ${p.tone ?? ""}`;
    case "collector.escalated":
      return `collector escalated to mediator`;
    case "charter.finalized":
      return `charter finalized · v${p.version}`;
    case "payout.order_solved":
      return `payout order solved`;
    default:
      return e.type;
  }
}
