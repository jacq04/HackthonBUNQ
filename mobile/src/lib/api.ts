import Constants from "expo-constants";
import { supabase } from "./supabase";

const BASE_URL =
  process.env.EXPO_PUBLIC_API_BASE_URL ??
  (Constants.expoConfig?.extra?.apiBaseUrl as string | undefined) ??
  "http://localhost:8000";

async function authHeaders(): Promise<Record<string, string>> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  return token ? { Authorization: `Bearer ${token}` } : {};
}

async function req<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = {
    "Content-Type": "application/json",
    ...(await authHeaders()),
    ...(init.headers || {}),
  };
  const resp = await fetch(`${BASE_URL}${path}`, { ...init, headers });
  if (!resp.ok) {
    const body = await resp.text().catch(() => "");
    throw new Error(`${resp.status} ${resp.statusText}: ${body}`);
  }
  return (await resp.json()) as T;
}

export const api = {
  health: () => req<{ status: string }>("/health"),

  // Groups
  createGroup: (body: {
    name: string;
    contribution_amount_cents: number;
    cycle_count: number;
    currency?: string;
  }) => req<any>("/groups", { method: "POST", body: JSON.stringify(body) }),
  listGroups: () => req<any[]>("/groups"),
  getGroup: (id: string) => req<any>(`/groups/${id}`),
  createInvite: (id: string) => req<{ token: string; deep_link: string }>(
    `/groups/${id}/invite`,
    { method: "POST" },
  ),
  joinGroup: (code: string) =>
    req<any>(`/groups/join`, { method: "POST", body: JSON.stringify({ code }) }),

  // Charter
  sendCharterMessage: (groupId: string, text: string) =>
    req<any>(`/groups/${groupId}/charter/messages`, {
      method: "POST",
      body: JSON.stringify({ text }),
    }),
  getCharter: (groupId: string) => req<any>(`/groups/${groupId}/charter`),
  signCharter: (groupId: string) =>
    req<any>(`/groups/${groupId}/charter/sign`, {
      method: "POST",
      body: JSON.stringify({ accept: true }),
    }),

  // Contribute
  contribute: (
    groupId: string,
    body: { amount_cents?: number; cycle_month?: number; counterparty_email?: string },
  ) =>
    req<any>(`/groups/${groupId}/contribute`, {
      method: "POST",
      body: JSON.stringify(body),
    }),

  // Payout
  solvePayoutOrder: (groupId: string) =>
    req<any>(`/groups/${groupId}/payout/order`, { method: "POST", body: "{}" }),
  runPayout: (
    groupId: string,
    body: { cycle_month: number; bunq_recipient_iban?: string; bunq_recipient_name?: string },
  ) =>
    req<any>(`/groups/${groupId}/payout/run`, {
      method: "POST",
      body: JSON.stringify(body),
    }),

  // Disputes
  createDispute: (
    groupId: string,
    body: { claim_text: string; amount_cents?: number; evidence_urls?: string[] },
  ) =>
    req<any>(`/groups/${groupId}/disputes`, {
      method: "POST",
      body: JSON.stringify(body),
    }),

  // Emergency
  createEmergency: (groupId: string, reason: string) =>
    req<any>(`/groups/${groupId}/emergencies`, {
      method: "POST",
      body: JSON.stringify({ reason }),
    }),
  emergencyConsent: (groupId: string, emergencyId: string, approve: boolean) =>
    req<any>(`/groups/${groupId}/emergencies/${emergencyId}/consent`, {
      method: "POST",
      body: JSON.stringify({ approve }),
    }),

  // Chat
  sendChat: (groupId: string, text: string) =>
    req<any>(`/groups/${groupId}/chat`, {
      method: "POST",
      body: JSON.stringify({ text }),
    }),
};
