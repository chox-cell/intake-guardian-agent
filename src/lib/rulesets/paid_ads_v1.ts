/**
 * paid_ads.v1 — Decision Cover (Paid Ads Agency Pack)
 * Proof-first, deterministic.
 *
 * Decision Output:
 * - rulesetId, score (0..100), tier (GREEN/YELLOW/RED), label
 * - reason, recommendedActions[]
 * - signals (transparent inputs)
 */
export type DecisionTier = "GREEN" | "YELLOW" | "RED";

export type PaidAdsSignals = {
  source?: string;  // zapier | n8n | api | manual
  channel?: string; // meta | google | paid-ads | mixed

  leadEmail?: string;
  leadName?: string;
  company?: string;

  // proof stack
  hasPixel?: boolean;
  hasConversionApi?: boolean;
  hasGtm?: boolean;
  hasUtm?: boolean;
  hasThankYouPage?: boolean;

  // assets/hygiene
  hasClearOffer?: boolean;
  hasLandingPage?: boolean;
  hasCreativeAssets?: boolean;

  // measurement (optional)
  spend30dEur?: number;
  conversions30d?: number;
  ctr?: number;    // 0..1
  cpcEur?: number;

  contradictions?: string[];
  notes?: string;
};

export type PaidAdsDecision = {
  rulesetId: string;
  score: number;
  tier: DecisionTier;
  label: "proceed" | "ask-proof" | "pause" | "refund";
  reason: string;
  recommendedActions: string[];
  signals: PaidAdsSignals;
  createdAt: string;
};

function clamp(n: number, a: number, b: number) {
  return Math.max(a, Math.min(b, n));
}

function scoreSignals(s: PaidAdsSignals) {
  let score = 70;

  // Proof stack (most important)
  if (s.hasPixel) score += 6; else score -= 10;
  if (s.hasConversionApi) score += 6; else score -= 6;
  if (s.hasGtm) score += 4; else score -= 4;
  if (s.hasUtm) score += 4; else score -= 6;
  if (s.hasThankYouPage) score += 4; else score -= 4;

  // Offer / LP / Creative
  if (s.hasClearOffer) score += 4; else score -= 6;
  if (s.hasLandingPage) score += 4; else score -= 6;
  if (s.hasCreativeAssets) score += 3; else score -= 3;

  // Soft measurement signals
  if (typeof s.spend30dEur === "number" && s.spend30dEur >= 300) score += 3;
  if (typeof s.conversions30d === "number" && s.conversions30d >= 3) score += 3;
  if (typeof s.ctr === "number" && s.ctr >= 0.01) score += 2; // >= 1%
  if (typeof s.cpcEur === "number" && s.cpcEur > 0 && s.cpcEur <= 5) score += 1;

  // Contradictions penalty
  const c = Array.isArray(s.contradictions) ? s.contradictions.length : 0;
  score -= c * 6;

  score = clamp(score, 0, 100);

  let tier: DecisionTier = "GREEN";
  if (score < 55) tier = "RED";
  else if (score < 75) tier = "YELLOW";

  return { score, tier };
}

function decideLabel(score: number, tier: DecisionTier) {
  if (tier === "RED" && score <= 40) return "refund" as const;
  if (tier === "RED") return "pause" as const;
  if (tier === "YELLOW") return "ask-proof" as const;
  return "proceed" as const;
}

function reasonFor(label: PaidAdsDecision["label"]) {
  if (label === "proceed") return "Proof stack looks healthy. Low contradiction.";
  if (label === "ask-proof") return "Proof gaps exist. Request tracking + clarity before scaling.";
  if (label === "pause") return "High risk: missing proof signals or contradictions. Pause spend until fixed.";
  return "Severe proof gaps. Recommend refund/reset before more spend.";
}

function actionsFor(label: PaidAdsDecision["label"]) {
  const common = ["Export Proof ZIP for client communication", "Log decision and archive context"];

  if (label === "proceed") {
    return ["Proceed with a limited budget ramp", "Send client Proof ZIP + 7-day plan", ...common];
  }
  if (label === "ask-proof") {
    return [
      "Request proof: Pixel + UTMs + thank-you page screenshots",
      "Confirm offer + landing page alignment",
      "Run a 48h low-budget validation after proof is complete",
      ...common,
    ];
  }
  if (label === "pause") {
    return [
      "Pause spend now",
      "Fix tracking stack: Pixel + CAPI + GTM + UTMs",
      "Re-check conversion path (events + thank-you page)",
      ...common,
    ];
  }
  return [
    "Refund/exit with written proof (avoid disputes)",
    "Offer restart only after proof stack is installed",
    ...common,
  ];
}

export function paidAdsV1FromAny(input: any): PaidAdsSignals {
  const raw = input || {};
  const lead = raw.lead || raw.booking || raw.payload?.lead || raw.payload?.booking || {};
  const channel =
    raw.channel || raw.lead?.channel || raw.payload?.channel || raw.tags?.channel || "paid-ads";

  const contradictions = Array.isArray(raw.contradictions) ? raw.contradictions : [];

  return {
    source: raw.source || raw.payload?.source || "api",
    channel,
    leadEmail: lead.email || raw.email,
    leadName: lead.fullName || lead.name || raw.fullName,
    company: lead.company || raw.company,

    hasPixel: Boolean(raw.hasPixel ?? raw.tracking?.hasPixel ?? raw.tracking?.pixel),
    hasConversionApi: Boolean(raw.hasConversionApi ?? raw.tracking?.hasConversionApi ?? raw.tracking?.capi),
    hasGtm: Boolean(raw.hasGtm ?? raw.tracking?.hasGtm ?? raw.tracking?.gtm),
    hasUtm: Boolean(raw.hasUtm ?? raw.tracking?.hasUtm ?? raw.tracking?.utm),
    hasThankYouPage: Boolean(raw.hasThankYouPage ?? raw.tracking?.hasThankYouPage ?? raw.tracking?.thankYouPage),

    hasClearOffer: Boolean(raw.hasClearOffer ?? raw.offer?.hasClearOffer ?? raw.offer?.clear),
    hasLandingPage: Boolean(raw.hasLandingPage ?? raw.assets?.hasLandingPage ?? raw.assets?.landingPage),
    hasCreativeAssets: Boolean(raw.hasCreativeAssets ?? raw.assets?.hasCreativeAssets ?? raw.assets?.creative),

    spend30dEur: typeof raw.spend30dEur === "number" ? raw.spend30dEur : undefined,
    conversions30d: typeof raw.conversions30d === "number" ? raw.conversions30d : undefined,
    ctr: typeof raw.ctr === "number" ? raw.ctr : undefined,
    cpcEur: typeof raw.cpcEur === "number" ? raw.cpcEur : undefined,

    contradictions,
    notes: raw.notes || raw.message || "",
  };
}

export function decidePaidAdsV1(input: any): PaidAdsDecision {
  const signals = paidAdsV1FromAny(input);
  const { score, tier } = scoreSignals(signals);
  const label = decideLabel(score, tier);

  return {
    rulesetId: "paid_ads.v1",
    score,
    tier,
    label,
    reason: reasonFor(label),
    recommendedActions: actionsFor(label),
    signals,
    createdAt: new Date().toISOString(),
  };
}
