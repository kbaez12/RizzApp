import Foundation

/// Central home for all fake AI responses used in Phase 2.
/// Nothing in the view layer should contain response strings.
///
/// All replies are written against the canonical mock conversation
/// (the "withholding content 😭" thread) so they read context-aware,
/// short, and human — demonstrating the actual product bar.
enum MockResponseCatalog {
    private static let labels: [GeneratedResponse.Strategy: String] = [
        .natural: "Natural",
        .bold: "Bolder",
        .advance: "Make a Move",
    ]

    private static func round(_ natural: String, _ bold: String, _ advance: String) -> [GeneratedResponse] {
        [
            GeneratedResponse(type: .natural, label: labels[.natural]!, text: natural),
            GeneratedResponse(type: .bold, label: labels[.bold]!, text: bold),
            GeneratedResponse(type: .advance, label: labels[.advance]!, text: advance),
        ]
    }

    /// Rounds of responses per goal. "Generate 3 More" cycles through rounds.
    static let rounds: [ResponseGoal: [[GeneratedResponse]]] = [
        .playful: [
            round(
                "gotta keep you interested somehow",
                "depends. what do i get for the premium stories?",
                "some stories are better in person. just saying"
            ),
            round(
                "rationing is self care, look it up",
                "you'll get the next one when you earn it",
                "come collect the full catalog over coffee then"
            ),
        ],
        .flirty: [
            round(
                "can't give you everything at once, where's the fun in that",
                "keeping you on the hook is the whole strategy",
                "tell you what, next one's in person. pick a day"
            ),
            round(
                "a little mystery looks good on me",
                "you're cute when you're demanding content",
                "drinks thursday and you get the unrated version"
            ),
        ],
        .funny: [
            round(
                "my stories are a limited series, not a sitcom",
                "sir this is a subscription service and you're on the free trial",
                "the season finale only screens in person"
            ),
            round(
                "the writers room needs time between episodes",
                "withholding?? i'm building suspense. it's called craft",
                "fine, live show. you bring snacks"
            ),
        ],
        .keepItGoing: [
            round(
                "ok fine, one more. but first — best concert you've ever been to?",
                "trade you. embarrassing story for embarrassing story",
                "i'll trade stories all night, easier over a drink though"
            ),
            round(
                "what's your equivalent? everyone has one chaotic story",
                "you first this time. make it good",
                "we clearly have enough material for a whole evening"
            ),
        ],
        .makeAMove: [
            round(
                "honestly these stories land way better in person",
                "let's skip ahead. when are you free this week?",
                "thursday. that little bar on 5th. i'll bring the stories"
            ),
            round(
                "we should swap the rest of these over coffee",
                "i'm done texting my best material. when am i seeing you?",
                "saturday. you pick the place, i'll pick the playlist"
            ),
        ],
        .recoverThis: [
            round(
                "ok that came out way more dramatic than intended lol",
                "the hoarding is strategic, not personal. promise",
                "let me make it up to you in person, stories included"
            ),
            round(
                "fair, i deserve that. next one's free",
                "ok you got me. premium unlocked, ask me anything",
                "i'll do formal apologies over tacos if you're in"
            ),
        ],
    ]

    /// Refined variants per action, written against the same conversation.
    /// Goal-agnostic for Phase 2 — the point is demonstrating the interaction.
    static let refined: [RefinementAction: [GeneratedResponse]] = [
        .shorter: round(
            "gotta keep some mystery",
            "earn the next one",
            "next story's in person"
        ),
        .bolder: round(
            "the good ones cost a coffee",
            "you're very invested for someone who hasn't asked me out yet",
            "stop stalling. thursday, drinks, full story"
        ),
        .moreLikeMe: round(
            "lol i pace my content",
            "i ration for a reason. demand stays high",
            "honestly these are better told in person"
        ),
        .lessCringe: round(
            "ha fair. i'll tell you the rest sometime",
            "you'll get the next one, promise",
            "next time we hang out i'll tell you the rest"
        ),
    ]
}
