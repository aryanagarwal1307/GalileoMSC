import { experimentConfig as config, materialPairs, type MaterialPair, type StudyType } from "./experiment.config";
import type { JatosApi } from "./jatos";

export type Reservation = { pair: MaterialPair; status: "reserved" | "completed" | "released"; reservedAt: string; completedAt?: string };
export type QuotaState = { type: StudyType; target: number; reservations: Record<string, Reservation> };
export type ProbeAllocation = { key: string; owner: string; pair: MaterialPair };

export function quotaCounts(state: QuotaState) {
  return materialPairs.map((pair) => ({
    pair,
    completed: Object.values(state.reservations).filter((r) => r.pair === pair && r.status === "completed").length,
    reserved: Object.values(state.reservations).filter((r) => r.pair === pair && r.status === "reserved").length,
  }));
}

export function reserveInState(state: QuotaState, owner: string, random = Math.random): Reservation {
  const existing = state.reservations[owner];
  if (existing && existing.status !== "released") return existing;
  const counts = quotaCounts(state);
  const available = counts.filter((count) => count.completed + count.reserved < state.target);
  if (!available.length) throw new Error("All study places are currently assigned. Please contact the researcher.");
  const lowest = Math.min(...available.map((count) => count.completed + count.reserved));
  const candidates = available.filter((count) => count.completed + count.reserved === lowest);
  const pair = candidates[Math.floor(random() * candidates.length)].pair;
  return state.reservations[owner] = { pair, status: "reserved", reservedAt: new Date().toISOString() };
}

async function updateQuota<T>(api: JatosApi, key: string, type: StudyType, update: (state: QuotaState) => T): Promise<T> {
  if (!api.batchSession) throw new Error("JATOS Batch Session is required for balanced probe assignment.");
  // JATOS rejects concurrent stale-version writes. Re-read and recompute on
  // EVERY retry; never replay a stale count or fall back to random assignment.
  api.batchSessionVersioning = true;
  for (let attempt = 0; attempt < 60; attempt++) {
    const stored = api.batchSession.get(key) as QuotaState | undefined;
    const state = stored ? structuredClone(stored) : { type, target: config.recruitment.quotaPerPair, reservations: {} };
    if (state.type !== type || state.target !== config.recruitment.quotaPerPair || !state.reservations ||
        Object.values(state.reservations).some((r) => !materialPairs.includes(r.pair) || !["reserved", "completed", "released"].includes(r.status))) {
      throw new Error("Probe quota configuration differs from this study. Check the JATOS Batch Session.");
    }
    const result = update(state);
    try {
      await api.batchSession.set(key, state);
      return result;
    } catch {
      // The server synchronizes the latest session/version before rejecting a
      // conflicting patch. A short jitter also spreads simultaneous arrivals.
      await new Promise((resolve) => setTimeout(resolve, 40 + Math.random() * 160));
    }
  }
  throw new Error("Could not synchronize the study assignment. Please retry.");
}

export async function allocateProbe(api: JatosApi, type: StudyType): Promise<ProbeAllocation | null> {
  if (type === "pre") return null;
  const identity = api.urlQueryParameters.PROLIFIC_PID ?? api.workerId ?? api.studyResultId;
  if (identity === undefined) throw new Error("A participant or JATOS worker ID is required for probe allocation.");
  const owner = `participant_${identity}`;
  const key = `${config.recruitment.batchSessionKey}_${type}`;
  const reservation = await updateQuota(api, key, type, (state) => reserveInState(state, owner));
  return { key, owner, pair: reservation.pair };
}

export async function completeProbe(api: JatosApi, allocation: ProbeAllocation, type: StudyType): Promise<void> {
  await updateQuota(api, allocation.key, type, (state) => {
    const reservation = state.reservations[allocation.owner];
    if (!reservation || reservation.pair !== allocation.pair || reservation.status === "released") {
      throw new Error("The probe reservation has changed. Please contact the researcher.");
    }
    reservation.status = "completed";
    reservation.completedAt ??= new Date().toISOString();
  });
}
