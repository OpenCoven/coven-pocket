extension CompanionChatModel {
    func updateTrafficAuthority(for terminal: Availability) {
        let nextAuthority: CompanionTrafficAuthority
        switch terminal {
        case let .ready(pairing):
            nextAuthority = .ready(pairing)
        case .blocked:
            nextAuthority = .unavailable
        case .idle, .checking:
            return
        }

        let advancesEpoch: Bool
        switch (trafficAuthority, nextAuthority) {
        case (nil, _):
            advancesEpoch = true
        case (.unavailable?, .unavailable):
            advancesEpoch = false
        case let (.ready(current)?, .ready(next)):
            advancesEpoch = !Self.isSameDaemonInstance(current, next)
        default:
            advancesEpoch = true
        }
        if advancesEpoch {
            trafficEpoch &+= 1
        }
        trafficAuthority = nextAuthority
    }
}
