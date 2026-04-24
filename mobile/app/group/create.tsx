import { useRouter } from "expo-router";
import { useState } from "react";
import {
  Alert,
  ScrollView,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api } from "@/lib/api";

export default function CreateGroup() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [amount, setAmount] = useState("50");
  const [cycles, setCycles] = useState("6");
  const [creating, setCreating] = useState(false);

  const submit = async () => {
    const cents = Math.round(parseFloat(amount) * 100);
    const n = parseInt(cycles, 10);
    if (!name.trim() || Number.isNaN(cents) || cents < 100 || Number.isNaN(n) || n < 2) {
      Alert.alert("Hmm", "Fill in a name, a valid amount, and at least 2 cycles.");
      return;
    }
    try {
      setCreating(true);
      const g = await api.createGroup({
        name,
        contribution_amount_cents: cents,
        cycle_count: n,
      });
      router.replace({ pathname: "/group/[id]/charter", params: { id: g.id } });
    } catch (e: any) {
      Alert.alert("Couldn't create", String(e?.message ?? e));
    } finally {
      setCreating(false);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <ScrollView contentContainerClassName="px-6 py-6">
        <Text className="text-3xl font-serif text-bowl mb-2">new circle</Text>
        <Text className="text-dusk/70 mb-6">
          Name the circle, set the contribution, and the number of cycles (= members).
        </Text>

        <Field label="name" value={name} onChange={setName} placeholder="Lagos Crew" />
        <Field
          label="contribution (EUR)"
          value={amount}
          onChange={setAmount}
          placeholder="50"
          keyboardType="decimal-pad"
        />
        <Field
          label="cycles / members"
          value={cycles}
          onChange={setCycles}
          placeholder="6"
          keyboardType="number-pad"
        />

        <TouchableOpacity
          onPress={submit}
          disabled={creating}
          className="bg-coral rounded-2xl py-4 items-center mt-4"
        >
          <Text className="text-cream font-semibold">
            {creating ? "creating…" : "create + start charter"}
          </Text>
        </TouchableOpacity>
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
}: {
  label: string;
  value: string;
  onChange: (s: string) => void;
  placeholder?: string;
  keyboardType?: any;
}) {
  return (
    <View className="mb-4">
      <Text className="text-dusk/70 mb-1 uppercase tracking-wide text-xs">{label}</Text>
      <TextInput
        className="bg-soft/60 rounded-2xl px-4 py-4 text-dusk text-base"
        placeholder={placeholder}
        placeholderTextColor="#2B2D2960"
        value={value}
        onChangeText={onChange}
        keyboardType={keyboardType}
      />
    </View>
  );
}
