/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./app/**/*.{js,jsx,ts,tsx}", "./src/**/*.{js,jsx,ts,tsx}"],
  presets: [require("nativewind/preset")],
  theme: {
    extend: {
      colors: {
        // Warm, community-coded palette — olive, cream, coral.
        bowl: "#3E4C29",   // deep olive
        cream: "#F5EEDC",  // page background
        coral: "#E9663C",  // primary CTA
        dusk: "#2B2D29",   // text
        soft: "#DBD4C0",   // muted surface
        success: "#6A9F55",
        warn: "#D8A23B",
        danger: "#C0443B",
        // Agent accents (chat bubbles)
        agent_constitution: "#D4A04A",
        agent_collector: "#5580C4",
        agent_mediator: "#8159B2",
        agent_emergency: "#C0443B",
        agent_coach: "#6A9F55",
        agent_router: "#9A9A8A",
      },
      fontFamily: {
        serif: ["Georgia", "serif"],
      },
    },
  },
  plugins: [],
};
