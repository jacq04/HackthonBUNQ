import { Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

export default function PassportTab() {
  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="flex-1 items-center justify-center px-10">
        <Text className="text-6xl mb-4">◈</Text>
        <Text className="text-2xl font-serif text-bowl mb-2">reputation passport</Text>
        <Text className="text-dusk/70 text-center">
          Your trust score, built cycle by cycle. Share it to join the next circle.
        </Text>
        <Text className="text-dusk/50 text-center mt-8 text-xs">
          (Shipped at end of first full cycle — see Auditor.)
        </Text>
      </View>
    </SafeAreaView>
  );
}
