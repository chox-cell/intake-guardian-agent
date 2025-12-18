import { Status } from "../types/contracts.js";

const allowed: Record<Status, Status[]> = {
  new: ["triage", "in_progress", "waiting", "resolved", "closed"],
  triage: ["in_progress", "waiting", "resolved", "closed"],
  in_progress: ["waiting", "resolved", "closed"],
  waiting: ["in_progress", "resolved", "closed"],
  resolved: ["closed"],
  closed: []
};

export function canTransition(from: Status, to: Status): boolean {
  return allowed[from].includes(to);
}
