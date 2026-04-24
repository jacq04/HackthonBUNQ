import { CameraView, useCameraPermissions } from "expo-camera";
import { useRouter } from "expo-router";
import { useState } from "react";
import { Alert, Text, TouchableOpacity, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { api } from "@/lib/api";

export default function Join() {
  const router = useRouter();
  const [permission, requestPermission] = useCameraPermissions();
  const [scanned, setScanned] = useState(false);

  const onScan = async ({ data }: { data: string }) => {
    if (scanned) return;
    setScanned(true);
    try {
      const code = parseCode(data);
      if (!code) {
        Alert.alert("Not a Kitty invite");
        setScanned(false);
        return;
      }
      const r = await api.joinGroup(code);
      router.replace({ pathname: "/group/[id]", params: { id: r.group_id } });
    } catch (e: any) {
      Alert.alert("Couldn't join", String(e?.message ?? e));
      setScanned(false);
    }
  };

  if (!permission) {
    return (
      <SafeAreaView className="flex-1 bg-cream items-center justify-center">
        <Text className="text-dusk/60">checking camera permission…</Text>
      </SafeAreaView>
    );
  }
  if (!permission.granted) {
    return (
      <SafeAreaView className="flex-1 bg-cream items-center justify-center p-10">
        <Text className="text-dusk mb-6 text-center">
          Camera access is needed to scan invite QR codes.
        </Text>
        <TouchableOpacity onPress={requestPermission} className="bg-coral rounded-2xl px-6 py-3 mb-3">
          <Text className="text-cream">grant camera access</Text>
        </TouchableOpacity>
        <TouchableOpacity onPress={() => router.back()} className="px-6 py-3">
          <Text className="text-dusk/60">back</Text>
        </TouchableOpacity>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView className="flex-1 bg-dusk">
      <CameraView
        style={{ flex: 1 }}
        barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
        onBarcodeScanned={scanned ? undefined : onScan}
      />
      <View className="py-6 items-center bg-dusk">
        <Text className="text-cream/80">scan a Kitty invite QR</Text>
        <TouchableOpacity onPress={() => router.back()} className="mt-3">
          <Text className="text-coral">cancel</Text>
        </TouchableOpacity>
      </View>
    </SafeAreaView>
  );
}

function parseCode(data: string): string | null {
  const m = data.match(/^kitty:\/\/join\?code=([^&\s]+)/);
  return m ? m[1] : null;
}
