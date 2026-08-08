import Foundation

/// Two rambles to run the organizer against on a real device: one short
/// enough to answer "does the model work at all", one long enough to time.
/// Both are written the way people actually talk into a phone — no
/// punctuation to lean on, facts scattered out of order — because a tidy
/// sample would flatter the model.
enum DiagnosticsSamples {
    /// About 80 words.
    static let short = """
    Okay so I'm walking out of the dentist and I need to remember a few \
    things. They said the crown on the lower left needs replacing, probably \
    eight hundred dollars, and I should call the insurance people to check \
    what's covered. Also Sarah's birthday is next Friday, I still haven't got \
    her anything, she likes those candles from the shop on Fourth. And I need \
    to move the car before street cleaning tomorrow morning, otherwise that's \
    another ticket.
    """

    /// About 400 words.
    static let long = """
    Right, kitchen. So the guy came by this morning, Marco, and he measured \
    everything and said the cabinets are basically fine structurally, it's the \
    doors that are shot, so we could reface instead of replacing and that saves \
    maybe four thousand. He quoted eleven two for the full replacement and \
    seven one for refacing, and that includes the hardware but not the counters. \
    Counters are separate, he said figure three to four thousand for quartz \
    depending on the slab, and there's a place in Santa Ana that does remnants \
    cheaper if we're okay with a smaller island. Which reminds me, the island \
    is the thing I keep going back and forth on, because if we do the island we \
    lose about eighteen inches of walkway on the fridge side and Mom is going to \
    hate that when she visits. Marco can start the second week of March, he's \
    booked until then, and he needs a deposit of thirty percent to hold the \
    date. He also said the sink we picked is too deep for the current plumbing, \
    so either we pick a shallower one or he brings in a plumber and that's \
    another six hundred or so. I told him I'd let him know by Friday. Separately \
    I need to call the city about the permit, because apparently if we move any \
    plumbing at all we need one, and the woman on the phone last time said it \
    takes two to three weeks which would blow the March start. Oh and the \
    appliance thing, the fridge we want is on backorder until April at Pacific \
    Sales but Ben said he saw the same model at the outlet in Fountain Valley for \
    two hundred less, so I should drive out there this weekend and see if it's \
    still there. Also we never decided on the backsplash. I like the zellige \
    tile but it's forty dollars a square foot installed because it takes longer \
    to set, and the subway tile is twelve. Emily wants the zellige. I think we \
    do subway in the main run and zellige behind the range as a feature, that's \
    maybe four hundred extra total. One more thing, the floor. If we're pulling \
    cabinets we should do the floor at the same time, otherwise there's a lip \
    where the old vinyl ends, and Marco says he doesn't do floors but he knows a \
    guy.
    """
}
