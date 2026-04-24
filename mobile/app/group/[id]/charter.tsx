import { useLocalSearchParams, useRouter } from "expo-router";
import { useEffect, useRef, useState } from "react";
import {
  Alert,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { AgentMessage } from "@/components/AgentMessage";
import { api } from "@/lib/api";
import { supabase } from "@/lib/supabase";

type Turn = { id: string; agent?: string | null; who?: string; text: string };

export default function Charter() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [turns, setTurns] = useState<Turn[]>([]);
  const [pending, setPending] = useState(false);
  const [text, setText] = useState("");
  const [draft, setDraft] = useState<Record<string, any> | null>(null);
  const [finalized, setFinalized] = useState(false);
  const listRef = useRef<FlatList<Turn>>(null);

  useEffect(() => {
    if (!id) return;
    (async () => {
      // Load prior messages from this group.
      const { data } = await supabase
        .from("messages")
        .select("id,sender_user_id,agent_name,text")
        .eq("group_id", id)
        .order("created_at");
      setTurns(
        (data ?? []).map((m: any) => ({
          id: m.id,
          agent: m.agent_name,
          text: m.text,
        })),
      );
    })();

    // Seed the Constitution dialog if this is a fresh group.
    setTimeout(() => {
      if (turns.length === 0) {
        onSend(
          "Let's start writing the charter. Ask me everything.",
        );
      }
    }, 300);
  }, [id]);

  const onSend = async (msg?: string) => {
    const t = (msg ?? text).trim();
    if (!t || !id) return;
    setText("");
    setPending(true);
    setTurns((p) => [...p, { id: `u-${Date.now()}`, text: t }]);
    try {
      const r = await api.sendCharterMessage(id, t);
      setTurns((p) => [
        ...p,
        { id: `a-${Date.now()}`, agent: "constitution", text: r.agent_reply },
      ]);
      if (r.draft) setDraft(r.draft);
      if (r.finalized) setFinalized(true);
    } catch (e: any) {
      Alert.alert("agent error", String(e?.message ?? e));
    } finally {
      setPending(false);
      setTimeout(() => listRef.current?.scrollToEnd({ animated: true }), 50);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        className="flex-1"
      >
        <View className="px-6 py-3 border-b border-soft">
          <Text className="text-xl font-serif text-bowl">charter</Text>
          <Text className="text-dusk/60 text-xs">
            Connie the Constitutor is co-drafting your circle's rules.
          </Text>
        </View>

        <FlatList
          ref={listRef}
          data={turns}
          keyExtractor={(t) => t.id}
          renderItem={({ item }) => (
            <AgentMessage
              agentName={item.agent ?? null}
              text={item.text}
              isCurrentUser={!item.agent}
            />
          )}
          contentContainerClassName="py-3"
        />

        {draft && (
          <View className="bg-soft/80 mx-4 mb-2 rounded-2xl p-3">
            <Text className="text-dusk/70 text-xs uppercase tracking-wide mb-1">
              current draft
            </Text>
            <Text className="text-dusk text-xs font-mono">
              {JSON.stringify(draft, null, 2)}
            </Text>
          </View>
        )}

        {finalized && (
          <View className="px-6 py-3">
            <TouchableOpacity
              onPress={() => router.replace({ pathname: "/group/[id]", params: { id } })}
              className="bg-success rounded-2xl py-3 items-center"
            >
              <Text className="text-cream font-semibold">
                charter finalized — back to circle
              </Text>
            </TouchableOpacity>
          </View>
        )}

        <View className="flex-row items-end gap-2 px-4 py-3 border-t border-soft">
          <TextInput
            className="flex-1 bg-soft/60 rounded-2xl px-4 py-3 text-dusk max-h-32"
            placeholder="say something to Connie…"
            placeholderTextColor="#2B2D2960"
            value={text}
            onChangeText={setText}
            multiline
          />
          <TouchableOpacity
            onPress={() => onSend()}
            disabled={pending || !text.trim()}
            className={`rounded-2xl px-4 py-3 ${pending || !text.trim() ? "bg-soft" : "bg-coral"}`}
          >
            <Text className="text-cream">send</Text>
          </TouchableOpacity>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
