import { Link, useFocusEffect, useLocalSearchParams } from "expo-router";
import { useCallback, useEffect, useState } from "react";
import { Alert, ScrollView, Text, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Pot } from "@/components/Pot";
import { LedgerTape } from "@/components/LedgerTape";
import { useGroupLedgerTape } from "@/lib/realtime";
import { api } from "@/lib/api";

export default function GroupDetail() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [group, setGroup] = useState<any>(null);
  const [members, setMembers] = useState<any[]>([]);
  const [charter, setCharter] = useState<any>(null);
  const events = useGroupLedgerTape(id);

  const load = useCallback(async () => {
    if (!id) return;
    const r = await api.getGroup(id);
    setGroup(r.group);
    setMembers(r.members);
    setCharter(r.charter);
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  // Refresh on return from the add-member screen.
  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  const filled_cents = events
    .filter((e) => e.type === "contribution.posted")
    .reduce((a, e) => a + ((e.payload?.amount_cents as number) ?? 0), 0);
  const target_cents =
    (group?.contribution_amount_cents ?? 0) * (group?.cycle_count ?? 0);

  const onInvite = async () => {
    if (!id) return;
    try {
      const inv = await api.createInvite(id);
      Alert.alert("Share this link", inv.deep_link);
    } catch (e: any) {
      Alert.alert("Couldn't make invite", String(e?.message ?? e));
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <ScrollView contentContainerClassName="pb-36">
        <View className="items-center pt-6">
          <Text className="text-2xl font-serif text-bowl">{group?.name ?? "…"}</Text>
          <Text className="text-dusk/60 mt-0.5">
            {group
              ? `€${(group.contribution_amount_cents / 100).toFixed(2)} · ${members.length}/${group.cycle_count} · ${group.status}`
              : ""}
          </Text>
          <View className="mt-4">
            <Pot filled_cents={filled_cents} target_cents={Math.max(target_cents, 1)} />
          </View>
          <Text className="text-dusk/60 mt-2">
            €{(filled_cents / 100).toFixed(2)} / €{(target_cents / 100).toFixed(2)}
          </Text>
        </View>

        <View className="px-6 mt-6">
          <View className="flex-row items-center justify-between mb-2">
            <Text className="text-dusk/70 uppercase tracking-wide text-xs">
              members ({members.length}/{group?.cycle_count ?? "?"})
            </Text>
            <Link href={{ pathname: "/group/[id]/add-member", params: { id } }} asChild>
              <TouchableOpacity>
                <Text className="text-coral text-xs font-semibold">+ add</Text>
              </TouchableOpacity>
            </Link>
          </View>
          <View className="bg-soft rounded-3xl py-2">
            {members.length === 0 ? (
              <Text className="text-dusk/50 italic text-center py-3">no members yet</Text>
            ) : (
              members.map((m: any) => (
                <View
                  key={m.user_id}
                  className="flex-row items-center px-4 py-2.5 border-b border-cream/60 last:border-b-0"
                >
                  <View className="w-8 h-8 rounded-full bg-bowl items-center justify-center mr-3">
                    <Text className="text-cream font-semibold text-xs">
                      {(m.users?.display_name ?? "?").charAt(0)}
                    </Text>
                  </View>
                  <View className="flex-1">
                    <Text className="text-dusk font-medium">
                      {m.users?.display_name ?? "unnamed"}
                      {m.role === "admin" ? "  ★" : ""}
                    </Text>
                    <Text className="text-dusk/50 text-xs">
                      cycle {m.payout_cycle ?? "—"} · {m.status}
                    </Text>
                  </View>
                </View>
              ))
            )}
          </View>
        </View>

        <View className="px-6 mt-6">
          <Text className="text-dusk/70 uppercase tracking-wide text-xs mb-2">ledger tape</Text>
          <View className="bg-soft rounded-3xl overflow-hidden" style={{ minHeight: 180 }}>
            <LedgerTape events={events} />
          </View>
        </View>

        <View className="px-6 mt-6 flex-row flex-wrap gap-3">
          {group?.status === "charter" && (
            <Link href={{ pathname: "/group/[id]/charter", params: { id } }} asChild>
              <TouchableOpacity className="bg-agent_constitution rounded-2xl px-4 py-3">
                <Text className="text-cream">continue charter →</Text>
              </TouchableOpacity>
            </Link>
          )}
          <Link href={{ pathname: "/group/[id]/contribute", params: { id } }} asChild>
            <TouchableOpacity className="bg-coral rounded-2xl px-4 py-3">
              <Text className="text-cream">contribute</Text>
            </TouchableOpacity>
          </Link>
          <Link href={{ pathname: "/group/[id]/dispute/new", params: { id } }} asChild>
            <TouchableOpacity className="bg-agent_mediator rounded-2xl px-4 py-3">
              <Text className="text-cream">raise dispute</Text>
            </TouchableOpacity>
          </Link>
          <Link href={{ pathname: "/group/[id]/emergency", params: { id } }} asChild>
            <TouchableOpacity className="bg-agent_emergency rounded-2xl px-4 py-3">
              <Text className="text-cream">emergency exit</Text>
            </TouchableOpacity>
          </Link>
          <Link href={{ pathname: "/group/[id]/add-member", params: { id } }} asChild>
            <TouchableOpacity className="bg-bowl rounded-2xl px-4 py-3">
              <Text className="text-cream">add from bunq</Text>
            </TouchableOpacity>
          </Link>
          <TouchableOpacity onPress={onInvite} className="bg-soft rounded-2xl px-4 py-3">
            <Text className="text-dusk">invite link</Text>
          </TouchableOpacity>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}
