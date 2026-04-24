import { Canvas, Circle, Group, Path, Skia } from "@shopify/react-native-skia";
import { useEffect } from "react";
import {
  useDerivedValue,
  useSharedValue,
  withSpring,
  withTiming,
} from "react-native-reanimated";

type Props = {
  filled_cents: number;
  target_cents: number;
  size?: number;
};

/** A literal bowl that fills with coin-colored liquid as contributions post. */
export function Pot({ filled_cents, target_cents, size = 260 }: Props) {
  const ratio = useSharedValue(0);

  useEffect(() => {
    const next = target_cents > 0 ? Math.min(1, filled_cents / target_cents) : 0;
    ratio.value = withSpring(next, { damping: 14, stiffness: 90 });
  }, [filled_cents, target_cents]);

  // The bowl is a semicircle clipped at `y = bowl_top - (ratio * bowl_height)`.
  const bowlRadius = size * 0.42;
  const bowlCenterX = size / 2;
  const bowlCenterY = size * 0.55;
  const bowlBottomY = bowlCenterY + bowlRadius;

  // Clip path describing the bowl interior.
  const bowlPath = Skia.Path.Make();
  bowlPath.moveTo(bowlCenterX - bowlRadius, bowlCenterY);
  bowlPath.addCircle(bowlCenterX, bowlCenterY, bowlRadius);
  bowlPath.close();

  const liquidY = useDerivedValue(() => {
    const travel = bowlRadius * 2 - 4;
    return bowlBottomY - ratio.value * travel;
  });

  return (
    <Canvas style={{ width: size, height: size }}>
      {/* Bowl rim */}
      <Circle
        cx={bowlCenterX}
        cy={bowlCenterY}
        r={bowlRadius + 4}
        color="#DBD4C0"
      />
      {/* Bowl inner */}
      <Circle cx={bowlCenterX} cy={bowlCenterY} r={bowlRadius} color="#F5EEDC" />

      {/* Liquid — a big coral-colored disc, clipped by the bowl. */}
      <Group clip={bowlPath}>
        <Path
          path={useDerivedValue(() => {
            const p = Skia.Path.Make();
            p.addRect({
              x: bowlCenterX - bowlRadius,
              y: liquidY.value,
              width: bowlRadius * 2,
              height: bowlBottomY - liquidY.value + 2,
            });
            return p;
          })}
          color="#E9663C"
        />
      </Group>

      {/* Bowl shadow at the bottom */}
      <Circle
        cx={bowlCenterX}
        cy={bowlBottomY + 12}
        r={bowlRadius * 0.85}
        color="rgba(43, 45, 41, 0.08)"
      />
    </Canvas>
  );
}
