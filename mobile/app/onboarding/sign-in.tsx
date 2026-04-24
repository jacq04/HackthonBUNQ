import { useState } from "react";
import {
  ActivityIndicator,
  Alert,
  FlatList,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api, type BunqUserCard } from "@/lib/api";
import { supabase } from "@/lib/supabase";

type Stage = "method" | "bunq-pick" | "email" | "email-code";

/**
 * Sign-in. Two paths:
 *   1. "Sign in with bunq" — picks from the sandbox users bootstrapped locally.
 *      The backend authenticates via that bunq session and mints a Supabase
 *      OTP we verify client-side. Result: one-tap sign-in linked to a real
 *      bunq identity (display name + IBAN).
 *   2. "Email me a code" — standard Supabase OTP. Fallback.
 */
export default function SignIn() {
  const [stage, setStage] = useState<Stage>("method");
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [bunqUsers, setBunqUsers] = useState<BunqUserCard[] | null>(null);

  // ─── bunq flow ───────────────────────────────────────────────────────────
  const openBunqPicker = async () => {
    setStage("bunq-pick");
    if (bunqUsers === null) {
      try {
        const list = await api.listBunqUsers();
        setBunqUsers(list);
      } catch (e: any) {
        Alert.alert("Couldn't load bunq users", String(e?.message ?? e));
        setStage("method");
      }
    }
  };

  const signInAsBunqUser = async (u: BunqUserCard) => {
    setBusy(true);
    try {
      const { email: boundEmail, otp } = await api.signinWithBunq(u.label);
      const { error } = await supabase.auth.verifyOtp({
        email: boundEmail,
        token: otp,
        type: "email",
      });
      if (error) throw error;
    } catch (e: any) {
      Alert.alert("Bunq sign-in failed", String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  };

  // ─── email flow ──────────────────────────────────────────────────────────
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
    setStage("email-code");
  };

  const verifyEmailOtp = async () => {
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
    if (error) Alert.alert("Didn't work", error.message);
  };

  // ─── render ──────────────────────────────────────────────────────────────
  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="flex-1 px-8 pt-16">
        <Text className="text-6xl font-serif text-bowl mb-2">Kitty</Text>
        <Text className="text-dusk text-lg mb-10">
          Rotating savings, with a pot that can't lie.
        </Text>

        {stage === "method" && (
          <View>
            <TouchableOpacity
              onPress={openBunqPicker}
              className="bg-coral rounded-2xl py-4 items-center mb-3 flex-row justify-center"
            >
              <Text className="text-cream text-xl mr-2">🐝</Text>
              <Text className="text-cream font-semibold text-base">
                sign in with bunq
              </Text>
            </TouchableOpacity>

            <TouchableOpacity
              onPress={() => setStage("email")}
              className="bg-soft rounded-2xl py-4 items-center"
            >
              <Text className="text-dusk font-semibold text-base">
                email me a code
              </Text>
            </TouchableOpacity>

            <Text className="text-dusk/50 text-xs text-center mt-10">
              Sandbox demo — "sign in with bunq" uses pre-minted test accounts.
            </Text>
          </View>
        )}

        {stage === "bunq-pick" && (
          <View className="flex-1">
            <Text className="text-dusk/70 mb-3 uppercase tracking-wide text-xs">
              pick a sandbox identity
            </Text>
            {bunqUsers === null ? (
              <ActivityIndicator color="#E9663C" />
            ) : bunqUsers.length === 0 ? (
              <Text className="text-dusk/60 italic">
                no bunq users cached — run `make bunq-bootstrap` on the backend host
              </Text>
            ) : (
              <FlatList
                data={bunqUsers}
                keyExtractor={(u) => u.label}
                ItemSeparatorComponent={() => <View className="h-3" />}
                renderItem={({ item }) => (
                  <TouchableOpacity
                    onPress={() => signInAsBunqUser(item)}
                    disabled={busy}
                    className="bg-soft rounded-2xl p-4 flex-row items-center"
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
                    <Text className="text-dusk/40">›</Text>
                  </TouchableOpacity>
                )}
              />
            )}

            {busy && (
              <View className="mt-4 items-center">
                <ActivityIndicator color="#E9663C" />
              </View>
            )}

            <TouchableOpacity
              onPress={() => setStage("method")}
              className="mt-6 items-center"
            >
              <Text className="text-dusk/60">back</Text>
            </TouchableOpacity>
          </View>
        )}

        {stage === "email" && (
          <View>
            <Text className="text-dusk/70 mb-2 uppercase tracking-wide text-xs">
              email
            </Text>
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
                <Text className="text-cream font-semibold text-base">
                  send code
                </Text>
              )}
            </TouchableOpacity>

            <TouchableOpacity
              onPress={() => setStage("method")}
              className="mt-4 items-center"
            >
              <Text className="text-dusk/60">back</Text>
            </TouchableOpacity>
          </View>
        )}

        {stage === "email-code" && (
          <View>
            <Text className="text-dusk mb-1">We sent a 6-digit code to</Text>
            <Text className="text-dusk font-semibold mb-6">{email}</Text>

            <Text className="text-dusk/70 mb-2 uppercase tracking-wide text-xs">
              code
            </Text>
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
              onPress={verifyEmailOtp}
              disabled={busy || code.length !== 6}
              className={`rounded-2xl py-4 items-center ${
                busy || code.length !== 6 ? "bg-soft" : "bg-coral"
              }`}
            >
              {busy ? (
                <ActivityIndicator color="#F5EEDC" />
              ) : (
                <Text className="text-cream font-semibold text-base">
                  verify
                </Text>
              )}
            </TouchableOpacity>

            <TouchableOpacity
              onPress={() => {
                setCode("");
                setStage("email");
              }}
              className="mt-4 items-center"
            >
              <Text className="text-dusk/60 text-sm">different email</Text>
            </TouchableOpacity>

            <Text className="text-dusk/50 text-xs text-center mt-8">
              Dev: emails arrive in Mailpit at {"\n"}http://127.0.0.1:54324
            </Text>
          </View>
        )}
      </View>
    </SafeAreaView>
  );
}
