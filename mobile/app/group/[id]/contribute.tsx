import * as Haptics from "expo-haptics";
import * as LocalAuthentication from "expo-local-authentication";
import { useLocalSearchParams, useRouter } from "expo-router";
import { useEffect, useState } from "react";
import { Alert, Text, TextInput, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api } from "@/lib/api";

export default function Contribute() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const [group, setGroup] = useState<any>(null);
  const [amount, setAmount] = useState("");
  const [email, setEmail] = useState("");
  const [paying, setPaying] = useState(false);

  useEffect(() => {
    (async () => {
      if (!id) return;
      const r = await api.getGroup(id);
      setGroup(r.group);
      setAmount((r.group.contribution_amount_cents / 100).toFixed(2));
    })();
  }, [id]);

  const confirm = async () => {
    if (!id) return;
    const cents = Math.round(parseFloat(amount) * 100);
    if (!cents || cents < 100) {
      Alert.alert("Hmm", "Amount is too small.");
      return;
    }

    // 1. FaceID / fingerprint gate.
    const has = await LocalAuthentication.hasHardwareAsync();
    if (has) {
      const res = await LocalAuthentication.authenticateAsync({
        promptMessage: `Confirm €${(cents / 100).toFixed(2)} to ${group?.name}`,
      });
      if (!res.success) {
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
        return;
      }
    }

    setPaying(true);
    try {
      const r = await api.contribute(id, {
        amount_cents: cents,
        counterparty_email: email || undefined,
      });
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
      Alert.alert(
        "Contribution pending",
        r.bunq_pay_url
          ? `Open this link to pay:\n${r.bunq_pay_url}`
          : "TigerBeetle transfer staged. In dev without bunq configured, use the replay endpoint to commit.",
        [{ text: "OK", onPress: () => router.back() }],
      );
    } catch (e: any) {
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      Alert.alert("Couldn't contribute", String(e?.message ?? e));
    } finally {
      setPaying(false);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="px-6 py-6">
        <Text className="text-3xl font-serif text-bowl mb-2">contribute</Text>
        <Text className="text-dusk/70 mb-6">
          {group
            ? `To the ${group.name} pot — you'll confirm with your face, then pay via bunq.`
            : "loading…"}
        </Text>

        <Text className="text-dusk/70 mb-1 uppercase tracking-wide text-xs">amount (EUR)</Text>
        <TextInput
          className="bg-soft/60 rounded-2xl px-4 py-4 text-dusk text-2xl mb-4"
          value={amount}
          onChangeText={setAmount}
          keyboardType="decimal-pad"
        />

        <Text className="text-dusk/70 mb-1 uppercase tracking-wide text-xs">your bunq email (optional)</Text>
        <TextInput
          className="bg-soft/60 rounded-2xl px-4 py-4 text-dusk text-base mb-8"
          placeholder="you@example.com"
          placeholderTextColor="#2B2D2960"
          value={email}
          onChangeText={setEmail}
          autoCapitalize="none"
          keyboardType="email-address"
        />

        <TouchableOpacity
          onPress={confirm}
          disabled={paying}
          className="bg-coral rounded-2xl py-4 items-center"
        >
          <Text className="text-cream font-semibold">
            {paying ? "sending…" : "confirm with face id"}
          </Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}
