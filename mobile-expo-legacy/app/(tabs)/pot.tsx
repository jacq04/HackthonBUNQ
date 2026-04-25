import { useState } from "react";
import { ScrollView, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Pot as PotGraphic } from "@/components/Pot";
import { LedgerTape } from "@/components/LedgerTape";
import { useGroupLedgerTape } from "@/lib/realtime";

/**
 * Tab-level Pot view — shows the first active group the user is in.
 * For single-group demos this is the main screen. In multi-group production
 * we'd surface a group picker at the top.
 */
export default function PotTab() {
  const [groupId] = useState<string | undefined>(undefined); // wired by route context in production
  const events = useGroupLedgerTape(groupId);

  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="items-center pt-6">
        <PotGraphic filled_cents={0} target_cents={100000} size={220} />
      </View>
      <Text className="text-dusk/70 text-center -mt-4 mb-2">
        Open a circle from Home to see its live pot.
      </Text>
      <View className="flex-1 mt-4">
        <LedgerTape events={events} />
      </View>
    </SafeAreaView>
  );
}
