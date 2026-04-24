import { useState } from "react";
import { Alert, Text, TextInput, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { supabase } from "@/lib/supabase";

export default function SignIn() {
  const [email, setEmail] = useState("");
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);

  const sendLink = async () => {
    if (!email.includes("@")) {
      Alert.alert("Hmm", "That doesn't look like an email.");
      return;
    }
    setSending(true);
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: "kitty://auth" },
    });
    setSending(false);
    if (error) {
      Alert.alert("Couldn't send link", error.message);
      return;
    }
    setSent(true);
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="flex-1 px-8 justify-center">
        <Text className="text-6xl font-serif text-bowl mb-2">Kitty</Text>
        <Text className="text-dusk text-lg mb-10">
          Rotating savings, with a pot that can't lie.
        </Text>

        {sent ? (
          <View>
            <Text className="text-dusk text-base mb-2">Link sent to {email}.</Text>
            <Text className="text-dusk/60">Tap it from your mail app to come back here.</Text>
          </View>
        ) : (
          <>
            <Text className="text-dusk/70 mb-2 uppercase tracking-wide text-xs">email</Text>
            <TextInput
              className="bg-soft/60 rounded-2xl px-4 py-4 text-dusk text-base mb-6"
              placeholder="you@example.com"
              placeholderTextColor="#2B2D2960"
              keyboardType="email-address"
              autoCapitalize="none"
              autoCorrect={false}
              value={email}
              onChangeText={setEmail}
            />
            <TouchableOpacity
              onPress={sendLink}
              disabled={sending}
              className="bg-coral rounded-2xl py-4 items-center"
            >
              <Text className="text-cream font-semibold text-base">
                {sending ? "sending…" : "send magic link"}
              </Text>
            </TouchableOpacity>
          </>
        )}
      </View>
    </SafeAreaView>
  );
}
