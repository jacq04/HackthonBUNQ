import { Redirect } from "expo-router";
import { useEffect, useState } from "react";
import { ActivityIndicator, View } from "react-native";
import { supabase } from "@/lib/supabase";
import type { Session } from "@supabase/supabase-js";

export default function Root() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
  }, []);

  if (session === undefined) {
    return (
      <View className="flex-1 items-center justify-center bg-cream">
        <ActivityIndicator color="#E9663C" />
      </View>
    );
  }
  return <Redirect href={session ? "/(tabs)/home" : "/onboarding/sign-in"} />;
}
