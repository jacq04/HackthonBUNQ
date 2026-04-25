import * as ImagePicker from "expo-image-picker";
import { useLocalSearchParams } from "expo-router";
import { useState } from "react";
import {
  Alert,
  Image,
  ScrollView,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api } from "@/lib/api";

export default function DisputeScreen() {
  const { id, disputeId } = useLocalSearchParams<{ id: string; disputeId: string }>();
  const isNew = disputeId === "new";
  const [claim, setClaim] = useState("");
  const [evidence, setEvidence] = useState<string[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [mediatorReply, setMediatorReply] = useState<string | null>(null);

  const pickEvidence = async () => {
    const res = await ImagePicker.launchCameraAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.Images,
      quality: 0.7,
    });
    if (!res.canceled && res.assets?.[0]) {
      setEvidence((p) => [...p, res.assets[0].uri]);
    }
  };

  const submit = async () => {
    if (!id || !claim.trim()) {
      Alert.alert("Hmm", "Describe the dispute in a sentence or two.");
      return;
    }
    setSubmitting(true);
    try {
      const r = await api.createDispute(id, {
        claim_text: claim.trim(),
        evidence_urls: evidence, // demo: local URIs (real impl uploads to storage)
      });
      setMediatorReply(r.mediator_reply);
    } catch (e: any) {
      Alert.alert("Couldn't file", String(e?.message ?? e));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <ScrollView contentContainerClassName="px-6 py-6">
        <Text className="text-3xl font-serif text-bowl mb-2">dispute</Text>
        <Text className="text-dusk/70 mb-6">
          Moti the Mediator reads TigerBeetle + bunq history + your evidence.
          You'll see a verdict here in about 6 seconds.
        </Text>

        {isNew ? (
          <>
            <Text className="text-dusk/70 mb-1 uppercase tracking-wide text-xs">your claim</Text>
            <TextInput
              className="bg-soft/60 rounded-2xl px-4 py-4 text-dusk text-base mb-4 min-h-28"
              placeholder="I paid the March contribution on the 3rd — bunq shows it, the pool doesn't."
              placeholderTextColor="#2B2D2960"
              value={claim}
              onChangeText={setClaim}
              multiline
              textAlignVertical="top"
            />

            <Text className="text-dusk/70 mb-1 uppercase tracking-wide text-xs">
              evidence (optional)
            </Text>
            <View className="flex-row flex-wrap gap-2 mb-2">
              {evidence.map((uri) => (
                <Image key={uri} source={{ uri }} className="w-24 h-24 rounded-xl" />
              ))}
            </View>
            <TouchableOpacity
              onPress={pickEvidence}
              className="bg-soft rounded-2xl py-3 items-center mb-6"
            >
              <Text className="text-dusk">📷 add a receipt photo</Text>
            </TouchableOpacity>

            <TouchableOpacity
              onPress={submit}
              disabled={submitting}
              className="bg-agent_mediator rounded-2xl py-4 items-center"
            >
              <Text className="text-cream font-semibold">
                {submitting ? "moti is reading…" : "file dispute"}
              </Text>
            </TouchableOpacity>
          </>
        ) : (
          <Text className="text-dusk/60">
            Dispute {disputeId}. (Detail view TBD.)
          </Text>
        )}

        {mediatorReply && (
          <View className="mt-6 bg-agent_mediator/10 border-l-4 border-agent_mediator rounded-2xl p-4">
            <Text className="text-xs uppercase tracking-wide text-dusk/60 mb-1">
              Moti · Mediator
            </Text>
            <Text className="text-dusk">{mediatorReply}</Text>
          </View>
        )}
      </ScrollView>
    </SafeAreaView>
  );
}
