import { Stack, useRouter, useSegments } from "expo-router";
import { useEffect, useState } from "react";
import { ActivityIndicator, View } from "react-native";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";
import { Session } from "@supabase/supabase-js";
import "../global.css";
import { supabase } from "@/lib/supabase";

export default function RootLayout() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const segments = useSegments();
  const router = useRouter();

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!ready) return;
    const inAuth = segments[0] === "onboarding";
    if (!session && !inAuth) {
      router.replace("/onboarding/sign-in");
    } else if (session && inAuth) {
      router.replace("/(tabs)/home");
    }
  }, [session, ready, segments]);

  if (!ready) {
    return (
      <View className="flex-1 items-center justify-center bg-cream">
        <ActivityIndicator color="#E9663C" />
      </View>
    );
  }

  return (
    <SafeAreaProvider>
      <StatusBar style="dark" />
      <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: "#F5EEDC" } }}>
        <Stack.Screen name="onboarding/sign-in" />
        <Stack.Screen name="onboarding/find-circle" options={{ title: "Find a circle" }} />
        <Stack.Screen name="(tabs)" />
        <Stack.Screen name="group/[id]/index" options={{ title: "Group" }} />
        <Stack.Screen name="group/[id]/charter" options={{ title: "Charter" }} />
        <Stack.Screen name="group/[id]/contribute" options={{ title: "Contribute" }} />
        <Stack.Screen name="group/[id]/emergency" options={{ title: "Emergency" }} />
        <Stack.Screen name="group/[id]/dispute/[disputeId]" options={{ title: "Dispute" }} />
        <Stack.Screen name="group/[id]/add-member" options={{ title: "Add Member" }} />
        <Stack.Screen name="group/create" options={{ title: "New Group" }} />
        <Stack.Screen name="group/join" options={{ title: "Join Group" }} />
      </Stack>
    </SafeAreaProvider>
  );
}
