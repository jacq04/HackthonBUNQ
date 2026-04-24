import { useState } from "react";
import {
  ActivityIndicator,
  Alert,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { supabase } from "@/lib/supabase";

type Stage = "email" | "code";

/**
 * Passwordless sign-in. Supabase sends both a magic link and a 6-digit OTP
 * to the user's inbox. We prefer the OTP path because it works without any
 * deep-link plumbing — paste the code, verify, signed in. The magic link
 * still works if the user clicks it (it opens kitty://auth).
 */
export default function SignIn() {
  const [stage, setStage] = useState<Stage>("email");
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);

  const sendCode = async () => {
    if (!email.includes("@")) {
      Alert.alert("Hmm", "That doesn't look like an email.");
      return;
    }
    setBusy(true);
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      options: { emailRedirectTo: "kitty://auth", shouldCreateUser: true },
    });
    setBusy(false);
    if (error) {
      Alert.alert("Couldn't send code", error.message);
      return;
    }
    setStage("code");
  };

  const verify = async () => {
    const token = code.replace(/\D/g, "");
    if (token.length !== 6) {
      Alert.alert("Hmm", "The code should be 6 digits.");
      return;
    }
    setBusy(true);
    const { error } = await supabase.auth.verifyOtp({
      email: email.trim().toLowerCase(),
      token,
      type: "email",
    });
    setBusy(false);
    if (error) {
      Alert.alert("Didn't work", error.message);
      return;
    }
    // auth state change listener in _layout.tsx handles the redirect to (tabs)/home
  };

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="flex-1 px-8 justify-center">
        <Text className="text-6xl font-serif text-bowl mb-2">Kitty</Text>
        <Text className="text-dusk text-lg mb-10">
          Rotating savings, with a pot that can't lie.
        </Text>

        {stage === "email" ? (
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
              editable={!busy}
            />
            <TouchableOpacity
              onPress={sendCode}
              disabled={busy}
              className="bg-coral rounded-2xl py-4 items-center"
            >
              {busy ? (
                <ActivityIndicator color="#F5EEDC" />
              ) : (
                <Text className="text-cream font-semibold text-base">send code</Text>
              )}
            </TouchableOpacity>
          </>
        ) : (
          <>
            <Text className="text-dusk mb-1">We sent a 6-digit code to</Text>
            <Text className="text-dusk font-semibold mb-6">{email}</Text>

            <Text className="text-dusk/70 mb-2 uppercase tracking-wide text-xs">code</Text>
            <TextInput
              className="bg-soft/60 rounded-2xl px-4 py-5 text-dusk text-3xl mb-6 text-center tracking-widest"
              placeholder="• • • • • •"
              placeholderTextColor="#2B2D2960"
              keyboardType="number-pad"
              maxLength={6}
              value={code}
              onChangeText={setCode}
              editable={!busy}
              autoFocus
            />
            <TouchableOpacity
              onPress={verify}
              disabled={busy || code.length !== 6}
              className={`rounded-2xl py-4 items-center ${
                busy || code.length !== 6 ? "bg-soft" : "bg-coral"
              }`}
            >
              {busy ? (
                <ActivityIndicator color="#F5EEDC" />
              ) : (
                <Text className="text-cream font-semibold text-base">verify</Text>
              )}
            </TouchableOpacity>

            <TouchableOpacity
              onPress={() => {
                setCode("");
                setStage("email");
              }}
              className="mt-4 items-center"
            >
              <Text className="text-dusk/60 text-sm">use a different email</Text>
            </TouchableOpacity>

            <Text className="text-dusk/50 text-xs text-center mt-8">
              Dev: emails arrive in Mailpit at {"\n"}http://127.0.0.1:54324
            </Text>
          </>
        )}
      </View>
    </SafeAreaView>
  );
}
