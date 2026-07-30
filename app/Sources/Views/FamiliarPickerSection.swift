import SwiftUI

struct FamiliarPresentation: Equatable {
    let id: String
    let displayName: String
    let glyph: String
    let role: String?

    init(remote: RemoteFamiliar) {
        id = remote.id
        displayName = remote.displayName
        glyph = Self.glyph(icon: remote.icon, emoji: remote.emoji)
        role = Self.nonblank(remote.role)
    }

    init(identity: FamiliarIdentity, roster: [RemoteFamiliar]) {
        let remote = roster.first {
            $0.id.caseInsensitiveCompare(identity.id) == .orderedSame
        }
        id = identity.id
        displayName = identity.displayName
        glyph = Self.glyph(
            icon: remote?.icon,
            emoji: identity.emoji ?? remote?.emoji
        )
        role = Self.nonblank(identity.role)
    }

    init(id: String) {
        self.id = id
        displayName = id
        glyph = "✦"
        role = nil
    }

    var accessibilityLabel: String {
        guard let role else { return displayName }
        return "\(displayName), \(role)"
    }

    private static func glyph(icon: String?, emoji: String?) -> String {
        for candidate in [icon, emoji] {
            guard let value = nonblank(candidate),
                  !value.lowercased().hasPrefix("ph:"),
                  URL(string: value)?.scheme == nil
            else { continue }
            return value
        }
        return "✦"
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct FamiliarSealValue: Equatable {
    enum Binding: Equatable {
        case activeConversation
        case nextSession

        var detail: String {
            switch self {
            case .activeConversation:
                return "Active for this conversation"
            case .nextSession:
                return "Selected for the next session"
            }
        }
    }

    let id: String
    let displayName: String
    let glyph: String
    let role: String?
    let binding: Binding
}

enum FamiliarSealResolver {
    static func onDevice(
        activeFamiliar: FamiliarIdentity?,
        hasActiveSession: Bool,
        selectedFamiliar: FamiliarIdentity?,
        roster: [RemoteFamiliar]
    ) -> FamiliarSealValue? {
        if hasActiveSession {
            guard let activeFamiliar else { return nil }
            return seal(
                FamiliarPresentation(
                    identity: activeFamiliar,
                    roster: roster
                ),
                binding: .activeConversation
            )
        }
        guard let selectedFamiliar else { return nil }
        return seal(
            FamiliarPresentation(
                identity: selectedFamiliar,
                roster: roster
            ),
            binding: .nextSession
        )
    }

    static func companion(
        sessionFamiliarID: String?,
        hasActiveSession: Bool,
        selectedFamiliar: FamiliarIdentity?,
        roster: [RemoteFamiliar]
    ) -> FamiliarSealValue? {
        if hasActiveSession {
            guard let sessionFamiliarID else { return nil }
            let presentation: FamiliarPresentation
            if let remote = roster.first(where: {
                $0.id.caseInsensitiveCompare(sessionFamiliarID) == .orderedSame
            }) {
                presentation = FamiliarPresentation(remote: remote)
            } else if let selectedFamiliar,
                      selectedFamiliar.id.caseInsensitiveCompare(
                        sessionFamiliarID
                      ) == .orderedSame {
                presentation = FamiliarPresentation(
                    identity: selectedFamiliar,
                    roster: roster
                )
            } else {
                presentation = FamiliarPresentation(id: sessionFamiliarID)
            }
            return seal(presentation, binding: .activeConversation)
        }
        guard let selectedFamiliar else { return nil }
        return seal(
            FamiliarPresentation(
                identity: selectedFamiliar,
                roster: roster
            ),
            binding: .nextSession
        )
    }

    private static func seal(
        _ presentation: FamiliarPresentation,
        binding: FamiliarSealValue.Binding
    ) -> FamiliarSealValue {
        FamiliarSealValue(
            id: presentation.id,
            displayName: presentation.displayName,
            glyph: presentation.glyph,
            role: presentation.role,
            binding: binding
        )
    }
}

struct FamiliarPickerSection: View {
    @Binding var settings: ChatSettings
    @ObservedObject var model: FamiliarSelectionModel
    let profile: FamiliarProfileKey?

    var body: some View {
        Section {
            Picker("Familiar", selection: selection) {
                Text("None").tag(nil as String?)
                ForEach(model.roster, id: \.id) { familiar in
                    FamiliarPickerLabel(
                        presentation: FamiliarPresentation(remote: familiar)
                    )
                    .tag(familiar.id as String?)
                }
            }
            .disabled(Self.isPickerDisabled(
                profile: profile,
                roster: model.roster,
                state: model.state
            ))
            .accessibilityHint(
                "Chooses the identity used when the next conversation starts."
            )

            status
        } footer: {
            Text(
                "Familiars shape identity. They never widen iOS tools or permissions."
            )
        }
    }

    static func reconcileSelection(
        _ id: String?,
        settings: inout ChatSettings,
        model: FamiliarSelectionModel,
        profile: FamiliarProfileKey?
    ) {
        guard let profile else {
            settings.familiarID = model.selectedFamiliar?.id
            return
        }
        model.select(id: id, for: profile)
        settings.familiarID = model.selectedFamiliar?.id
    }

    static func isPickerDisabled(
        profile: FamiliarProfileKey?,
        roster: [RemoteFamiliar],
        state: FamiliarSelectionModel.State
    ) -> Bool {
        guard profile != nil, !roster.isEmpty else { return true }
        return state == .loading
    }

    private var selection: Binding<String?> {
        Binding(
            get: { settings.familiarID },
            set: { id in
                Self.reconcileSelection(
                    id,
                    settings: &settings,
                    model: model,
                    profile: profile
                )
            }
        )
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle:
            if profile == nil {
                Text(unavailableCopy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("Load familiars") {
                    Task { await refresh() }
                }
                .accessibilityHint("Loads familiars from the paired daemon.")
            }
        case .loading:
            ProgressView("Loading familiars…")
        case .loaded where model.roster.isEmpty:
            Text("No familiars are configured.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .loaded:
            EmptyView()
        case let .failed(reason):
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await refresh() }
            }
            .accessibilityHint("Attempts to reload the familiar roster.")
        }
    }

    private var unavailableCopy: String {
        switch settings.backend {
        case .companionClaude:
            return "Pair with a daemon in Companion to choose a familiar."
        case .codex:
            return "Sign in with ChatGPT to choose a familiar for this profile."
        }
    }

    private func refresh() async {
        await model.refresh()
    }
}

private struct FamiliarPickerLabel: View {
    let presentation: FamiliarPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.glyph)
                .foregroundStyle(.purple)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.displayName)
                if let role = presentation.role {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

struct FamiliarIdentitySeal: View {
    let value: FamiliarSealValue

    var body: some View {
        Menu {
            Text(value.displayName)
            if let role = value.role {
                Text(role)
            }
            Divider()
            Text(value.binding.detail)
        } label: {
            HStack(spacing: 4) {
                Text(value.glyph)
                    .accessibilityHidden(true)
                Text(value.displayName)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.purple)
        }
        .accessibilityLabel("Familiar \(value.displayName)")
        .accessibilityHint(value.binding.detail)
    }
}
