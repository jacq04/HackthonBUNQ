import { Link, useFocusEffect } from "expo-router";
import { useCallback, useState } from "react";
import { FlatList, RefreshControl, Text, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api } from "@/lib/api";
import { supabase } from "@/lib/supabase";

export default function Home() {
  const [groups, setGroups] = useState<any[]>([]);
  const [refreshing, setRefreshing] = useState(false);

  const load = useCallback(async () => {
    try {
      setRefreshing(true);
      const r = await api.listGroups();
      setGroups(r);
    } catch (e) {
      console.warn("home.load", e);
    } finally {
      setRefreshing(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      load();
    }, [load]),
  );

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="flex-row items-center justify-between px-6 pt-4 pb-2">
        <Text className="text-3xl font-serif text-bowl">your circles</Text>
        <TouchableOpacity onPress={() => supabase.auth.signOut()}>
          <Text className="text-dusk/60">sign out</Text>
        </TouchableOpacity>
      </View>

      <FlatList
        className="flex-1"
        contentContainerClassName="px-6 pb-24"
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={load} tintColor="#E9663C" />}
        data={groups}
        keyExtractor={(g) => g.id}
        ListEmptyComponent={() => (
          <View className="py-12 items-center">
            <Text className="text-dusk/60 italic mb-6">no circles yet — start one or join one</Text>
          </View>
        )}
        renderItem={({ item }) => (
          <Link href={{ pathname: "/group/[id]", params: { id: item.id } }} asChild>
            <TouchableOpacity className="bg-soft rounded-3xl p-5 mb-4">
              <Text className="text-xl text-bowl font-serif mb-1">{item.name}</Text>
              <Text className="text-dusk/70">
                €{(item.contribution_amount_cents / 100).toFixed(2)} · {item.cycle_count} cycles · {item.status}
              </Text>
            </TouchableOpacity>
          </Link>
        )}
      />

      <View className="absolute bottom-8 left-6 right-6 flex-row gap-3">
        <Link href="/onboarding/find-circle" asChild>
          <TouchableOpacity className="bg-coral rounded-2xl py-4 flex-1 items-center">
            <Text className="text-cream font-semibold">find a circle</Text>
          </TouchableOpacity>
        </Link>
        <Link href="/group/join" asChild>
          <TouchableOpacity className="bg-bowl rounded-2xl py-4 flex-1 items-center">
            <Text className="text-cream font-semibold">join by code</Text>
          </TouchableOpacity>
        </Link>
      </View>
    </SafeAreaView>
  );
}
