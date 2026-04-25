import { Tabs } from "expo-router";
import { Ionicons } from "@expo/vector-icons";

export default function TabsLayout() {
  return (
    <Tabs
      screenOptions={({ route }) => ({
        headerShown: false,
        tabBarActiveTintColor: "#E9663C",
        tabBarInactiveTintColor: "#2B2D2980",
        tabBarStyle: { backgroundColor: "#F5EEDC", borderTopColor: "#DBD4C0" },
        tabBarIcon: ({ color, size }) => {
          const name =
            route.name === "home" ? "home-outline" :
            route.name === "pot" ? "fish-outline" :
            route.name === "chat" ? "chatbubbles-outline" :
            "ribbon-outline";
          return <Ionicons name={name as any} size={size} color={color} />;
        },
      })}
    >
      <Tabs.Screen name="home" options={{ title: "Home" }} />
      <Tabs.Screen name="pot" options={{ title: "Pot" }} />
      <Tabs.Screen name="chat" options={{ title: "Chat" }} />
      <Tabs.Screen name="passport" options={{ title: "Passport" }} />
    </Tabs>
  );
}
