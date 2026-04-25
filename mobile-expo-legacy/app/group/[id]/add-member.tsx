import { useLocalSearchParams, useRouter } from "expo-router";
import { useCallback, useEffect, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api, type BunqUserCard } from "@/lib/api";

/**
 * Group admin picks bunq sandbox users to add as members.
 * Listed users are filtered to exclude people already in the group.
 * Tap a row → backend links the bunq identity + creates the membership.
 */
export default function AddMember() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [candidates, setCandidates] = useState<BunqUserCard[] | null>(null);
  const [adding, setAdding] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!id) return;
    try {
      setCandidates(null);
      const list = await api.listMemberCandidates(id);
      setCandidates(list);
    } catch (e: any) {
      Alert.alert("Couldn't load candidates", String(e?.message ?? e));
      setCandidates([]);
    }
  }, [id]);

  useEffect(() => {
    load();
  }, [load]);

  const add = async (u: BunqUserCard) => {
    if (!id) return;
    setAdding(u.label);
    try {
      const r = await api.addBunqMember(id, u.label);
      Alert.alert(
        "Added",
        `${r.display_name} joined${r.payout_cycle ? ` at cycle ${r.payout_cycle}` : ""}.`,
        [{ text: "OK", onPress: () => router.back() }],
      );
    } catch (e: any) {
      Alert.alert("Couldn't add", String(e?.message ?? e));
    } finally {
      setAdding(null);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="px-6 pt-6 pb-3">
        <Text className="text-3xl font-serif text-bowl mb-1">add member</Text>
        <Text className="text-dusk/70">
          Pick a bunq identity to add to the circle.
        </Text>
      </View>

      {candidates === null ? (
        <View className="flex-1 items-center justify-center">
          <ActivityIndicator color="#E9663C" />
        </View>
      ) : candidates.length === 0 ? (
        <View className="flex-1 items-center justify-center px-10">
          <Text className="text-dusk/60 italic text-center">
            Every cached bunq identity is already in this circle. Run
            `make bunq-bootstrap` on the host to mint more.
          </Text>
        </View>
      ) : (
        <FlatList
          data={candidates}
          keyExtractor={(u) => u.label}
          ItemSeparatorComponent={() => <View className="h-3" />}
          contentContainerClassName="px-6 pb-24"
          renderItem={({ item }) => {
            const busy = adding === item.label;
            return (
              <TouchableOpacity
                onPress={() => add(item)}
                disabled={adding !== null}
                className={`bg-soft rounded-2xl p-4 flex-row items-center ${
                  adding && !busy ? "opacity-50" : ""
                }`}
              >
                <View className="w-10 h-10 rounded-full bg-bowl items-center justify-center mr-3">
                  <Text className="text-cream font-semibold">
                    {item.display_name.charAt(0)}
                  </Text>
                </View>
                <View className="flex-1">
                  <Text className="text-dusk font-semibold">
                    {item.display_name}
                  </Text>
                  <Text className="text-dusk/60 text-xs mt-0.5">
                    {item.primary_iban ?? `#${item.bunq_user_id}`}
                  </Text>
                </View>
                {busy ? (
                  <ActivityIndicator color="#E9663C" />
                ) : (
                  <Text className="text-coral text-lg">+</Text>
                )}
              </TouchableOpacity>
            );
          }}
        />
      )}

      <View className="absolute bottom-8 left-6 right-6">
        <TouchableOpacity
          onPress={() => router.back()}
          className="bg-dusk rounded-2xl py-4 items-center"
        >
          <Text className="text-cream">done</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}
