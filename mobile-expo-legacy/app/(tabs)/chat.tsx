import { Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";

export default function ChatTab() {
  return (
    <SafeAreaView className="flex-1 bg-cream">
      <View className="flex-1 items-center justify-center px-10">
        <Text className="text-2xl font-serif text-bowl mb-2">crew chat</Text>
        <Text className="text-dusk/70 text-center">
          Open a circle from Home to chat with members and agents together.
        </Text>
      </View>
    </SafeAreaView>
  );
}
