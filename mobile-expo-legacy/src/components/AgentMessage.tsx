import { Text, View } from "react-native";

const AGENT_COLOR: Record<string, string> = {
  constitution: "bg-agent_constitution/20 border-agent_constitution",
  collector: "bg-agent_collector/20 border-agent_collector",
  mediator: "bg-agent_mediator/20 border-agent_mediator",
  emergency: "bg-agent_emergency/20 border-agent_emergency",
  coach: "bg-agent_coach/20 border-agent_coach",
  router: "bg-agent_router/20 border-agent_router",
  system: "bg-soft border-dusk/20",
};

const AGENT_TITLE: Record<string, string> = {
  constitution: "Connie · Constitution",
  collector: "Coby · Collector",
  mediator: "Moti · Mediator",
  emergency: "Ella · Emergency",
  coach: "Kalu · Coach",
  router: "Ray · Router",
  system: "Kitty",
};

type Props = {
  agentName: string | null;
  senderDisplayName?: string | null;
  text: string;
  time?: string;
  isCurrentUser?: boolean;
};

export function AgentMessage({ agentName, senderDisplayName, text, time, isCurrentUser }: Props) {
  if (!agentName) {
    return (
      <View
        className={`my-1 px-4 max-w-[85%] ${isCurrentUser ? "self-end" : "self-start"}`}
      >
        <View
          className={`rounded-2xl px-4 py-2 ${
            isCurrentUser ? "bg-dusk" : "bg-soft"
          }`}
        >
          <Text className={isCurrentUser ? "text-cream" : "text-dusk"}>{text}</Text>
        </View>
        {senderDisplayName && (
          <Text className="text-xs text-dusk/50 mt-0.5 px-1">
            {senderDisplayName}
            {time ? ` · ${time}` : ""}
          </Text>
        )}
      </View>
    );
  }

  const colorCls = AGENT_COLOR[agentName] ?? AGENT_COLOR.system;
  const title = AGENT_TITLE[agentName] ?? agentName;

  return (
    <View className="my-1 px-4 max-w-[92%] self-start">
      <Text className="text-xs text-dusk/60 mb-1 uppercase tracking-wide">{title}</Text>
      <View className={`rounded-2xl px-4 py-3 border-l-4 ${colorCls}`}>
        <Text className="text-dusk">{text}</Text>
      </View>
    </View>
  );
}
