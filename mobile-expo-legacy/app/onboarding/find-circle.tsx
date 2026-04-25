import { useRouter } from "expo-router";
import { useState } from "react";
import {
  ActivityIndicator,
  Alert,
  ScrollView,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api } from "@/lib/api";

type Urgency = "low" | "medium" | "high";

/**
 * The only entry point into a circle. User describes what they want, the
 * Matchmaker agent decides JOIN / FORM / WAITLIST.
 */
export default function FindCircle() {
  const router = useRouter();
  const [amount, setAmount] = useState("50");
  const [cycles, setCycles] = useState("6");
  const [goal, setGoal] = useState("");
  const [urgency, setUrgency] = useState<Urgency>("medium");
  const [culture, setCulture] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    const cents = Math.round(parseFloat(amount) * 100);
    const n = parseInt(cycles, 10);
    if (!goal.trim() || Number.isNaN(cents) || cents < 500 || Number.isNaN(n) || n < 2) {
      Alert.alert("Hmm", "Need a goal, an amount (≥ €5), and ≥ 2 cycles.");
      return;
    }
    setBusy(true);
    try {
      const r = await api.findCircle({
        contribution_amount_cents: cents,
        cycle_count: n,
        goal: goal.trim(),
        urgency,
        cultural_hint: culture.trim() || null,
      });

      if (r.action === "joined" && r.group_id) {
        Alert.alert(
          "You're in",
          `Matched to ${r.group_name ?? "a circle"} at cycle ${r.payout_cycle ?? "?"}.\n\nTrust score: ${r.trust_score}\n\n${r.rationale}`,
          [{ text: "Open", onPress: () => router.replace({ pathname: "/group/[id]", params: { id: r.group_id! } }) }],
        );
      } else if (r.action === "formed" && r.group_id) {
        Alert.alert(
          "New circle formed",
          `${r.group_name} is yours to found.\n\nTrust score: ${r.trust_score}\n\n${r.rationale}`,
          [{ text: "Open", onPress: () => router.replace({ pathname: "/group/[id]", params: { id: r.group_id! } }) }],
        );
      } else if (r.action === "waitlisted") {
        Alert.alert(
          "On the waitlist",
          `We'll ping you when enough people share your shape.\n\nTrust score: ${r.trust_score}\n\n${r.rationale}`,
          [{ text: "OK", onPress: () => router.replace("/(tabs)/home") }],
        );
      } else {
        Alert.alert("Hmm", r.rationale || "Matchmaker didn't decide — try again.");
      }
    } catch (e: any) {
      Alert.alert("Matchmaker failed", String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <ScrollView contentContainerClassName="px-6 py-6">
        <Text className="text-3xl font-serif text-bowl mb-1">find a circle</Text>
        <Text className="text-dusk/70 mb-6">
          Tell us what you're saving for. Kitty's Matchmaker does the rest.
        </Text>

        <Field
          label="what for"
          value={goal}
          onChange={setGoal}
          placeholder="tuition deposit · wedding · emergency fund"
          multiline
        />
        <Field
          label="per month (EUR)"
          value={amount}
          onChange={setAmount}
          keyboardType="decimal-pad"
        />
        <Field
          label="over how many months"
          value={cycles}
          onChange={setCycles}
          keyboardType="number-pad"
        />

        <Text className="text-dusk/70 mb-2 uppercase tracking-wide text-xs">urgency</Text>
        <View className="flex-row gap-2 mb-4">
          {(["low", "medium", "high"] as Urgency[]).map((u) => (
            <TouchableOpacity
              key={u}
              onPress={() => setUrgency(u)}
              className={`px-4 py-2 rounded-2xl ${urgency === u ? "bg-coral" : "bg-soft"}`}
            >
              <Text className={urgency === u ? "text-cream font-semibold" : "text-dusk"}>
                {u}
              </Text>
            </TouchableOpacity>
          ))}
        </View>

        <Field
          label="tradition (optional)"
          value={culture}
          onChange={setCulture}
          placeholder="Susu · Chit fund · Tanda · Tontine · Kye · Hui"
        />

        <TouchableOpacity
          onPress={submit}
          disabled={busy}
          className="bg-coral rounded-2xl py-4 items-center mt-3"
        >
          {busy ? (
            <ActivityIndicator color="#F5EEDC" />
          ) : (
            <Text className="text-cream font-semibold">ask the matchmaker</Text>
          )}
        </TouchableOpacity>

        <TouchableOpacity onPress={() => router.back()} className="mt-4 items-center">
          <Text className="text-dusk/60">back</Text>
        </TouchableOpacity>

        <Text className="text-dusk/50 text-xs text-center mt-10 italic">
          Kitty runs a Vetting agent on your bunq history, then the Matchmaker
          agent either joins you to an open circle, forms a new one with
          compatible savers, or waitlists you until the fit exists.
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

function Field({
  label,
  value,
  onChange,
  placeholder,
  keyboardType,
  multiline,
}: {
  label: string;
  value: string;
  onChange: (s: string) => void;
  placeholder?: string;
  keyboardType?: any;
  multiline?: boolean;
}) {
  return (
    <View className="mb-4">
      <Text className="text-dusk/70 mb-1 uppercase tracking-wide text-xs">{label}</Text>
      <TextInput
        className={`bg-soft/60 rounded-2xl px-4 py-4 text-dusk text-base ${multiline ? "min-h-20" : ""}`}
        placeholder={placeholder}
        placeholderTextColor="#2B2D2960"
        value={value}
        onChangeText={onChange}
        keyboardType={keyboardType}
        multiline={multiline}
        textAlignVertical={multiline ? "top" : "center"}
      />
    </View>
  );
}
