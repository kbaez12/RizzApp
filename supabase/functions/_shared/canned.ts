// Phase 4A canned data. Deterministic, realistic enough for the existing
// Results UI. Replaced by real AI generation in Phase 5.
// Wire format is snake_case, matching the Swift client's decoder.

export interface CannedResponse {
  type: "natural" | "bold" | "advance";
  label: string;
  text: string;
}

export const CANNED_RESPONSES: CannedResponse[] = [
  {
    type: "natural",
    label: "Natural",
    text: "gotta keep you interested somehow",
  },
  {
    type: "bold",
    label: "Bolder",
    text: "depends. what do i get for the premium stories?",
  },
  {
    type: "advance",
    label: "Make a Move",
    text: "some stories are better in person. just saying",
  },
];

export const CANNED_REFINED: Record<string, CannedResponse[]> = {
  shorter: [
    { type: "natural", label: "Natural", text: "gotta keep some mystery" },
    { type: "bold", label: "Bolder", text: "earn the next one" },
    { type: "advance", label: "Make a Move", text: "next story's in person" },
  ],
  bolder: [
    { type: "natural", label: "Natural", text: "the good ones cost a coffee" },
    {
      type: "bold",
      label: "Bolder",
      text: "you're very invested for someone who hasn't asked me out yet",
    },
    {
      type: "advance",
      label: "Make a Move",
      text: "stop stalling. thursday, drinks, full story",
    },
  ],
  more_like_me: [
    { type: "natural", label: "Natural", text: "lol i pace my content" },
    {
      type: "bold",
      label: "Bolder",
      text: "i ration for a reason. demand stays high",
    },
    {
      type: "advance",
      label: "Make a Move",
      text: "honestly these are better told in person",
    },
  ],
  less_cringe: [
    {
      type: "natural",
      label: "Natural",
      text: "ha fair. i'll tell you the rest sometime",
    },
    { type: "bold", label: "Bolder", text: "you'll get the next one, promise" },
    {
      type: "advance",
      label: "Make a Move",
      text: "next time we hang out i'll tell you the rest",
    },
  ],
};

// After a canned generation: one analysis notionally consumed.
export const CANNED_USAGE_AFTER_GENERATE = {
  remaining: 4,
  limit: 5,
  tier: "free",
  refinements_remaining: 2,
};

// GET /usage baseline.
export const CANNED_USAGE_INITIAL = {
  remaining: 5,
  limit: 5,
  tier: "free",
  refinements_remaining: 2,
};

export const CANNED_USAGE_EXHAUSTED = {
  remaining: 0,
  limit: 5,
  tier: "free",
  refinements_remaining: 0,
};
