import * as Haptics from "expo-haptics";
import * as LocalAuthentication from "expo-local-authentication";
import { useLocalSearchParams, useRouter } from "expo-router";
import { useState } from "react";
import { Alert, ScrollView, Text, TextInput, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api } from "@/lib/api";

export default function Emergency() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [agentReply, setAgentReply] = useState<string | null>(null);

  const submit = async () => {
    if (!id || !reason.trim()) {
      Alert.alert("Need a reason", "Help the group understand what's happening.");
      return;
    }
    const auth = await LocalAuthentication.authenticateAsync({
      promptMessage: "Confirm emergency exit request",
    });
    if (!auth.success) {
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
      return;
    }
    try {
      setSubmitting(true);
      const r = await api.createEmergency(id, reason.trim());
      setAgentReply(r.agent_reply);
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy);
    } catch (e: any) {
      Alert.alert("Couldn't submit", String(e?.message ?? e));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <ScrollView contentContainerClassName="px-6 py-6">
        <Text className="text-3xl font-serif text-bowl mb-2">emergency exit</Text>
        <Text className="text-dusk/70 mb-6">
          Ella the Emergency agent will compute a fair buyout and share it with the
          group. Nothing moves until the group consents.
        </Text>

        <Text className="text-dusk/70 mb-1 uppercase tracking-wide text-xs">
          what's happening?
        </Text>
        <TextInput
          className="bg-soft/60 rounded-2xl px-4 py-4 text-dusk text-base mb-6 min-h-32"
          placeholder="e.g. sudden medical cost, my aunt's surgery this week…"
          placeholderTextColor="#2B2D2960"
          value={reason}
          onChangeText={setReason}
          multiline
          textAlignVertical="top"
        />

        <TouchableOpacity
          onPress={submit}
          disabled={submitting}
          className="bg-agent_emergency rounded-2xl py-4 items-center mb-4"
        >
          <Text className="text-cream font-semibold">
            {submitting ? "submitting…" : "request buyout"}
          </Text>
        </TouchableOpacity>

        {agentReply && (
          <View className="bg-agent_emergency/10 border-l-4 border-agent_emergency rounded-2xl p-4">
            <Text className="text-xs uppercase tracking-wide text-dusk/60 mb-1">
              Ella · Emergency
            </Text>
            <Text className="text-dusk">{agentReply}</Text>
          </View>
        )}
      </ScrollView>
    </SafeAreaView>
  );
}
