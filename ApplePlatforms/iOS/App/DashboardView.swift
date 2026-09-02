import SwiftUI

struct DashboardView: View {
  @ObservedObject var store: DashboardStore

  private var snapshot: AgentIslandSnapshot { store.snapshot }
  private var releaseLinks: DashboardReleaseLinks { DashboardReleaseLinks() }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          syncHeader

          if let errorMessage = store.errorMessage {
            errorBanner(errorMessage)
          }

          summaryGrid

          if snapshot.relevantAgents.isEmpty {
            emptyState
          } else {
            agentSection
          }

          liveActivitySection
          privacyNote
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle(Text(verbatim: releaseLinks.displayName))
      .toolbar { privacyToolbar }
      .refreshable { await store.refresh() }
    }
  }

  private var syncHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Circle()
        .fill(syncIndicatorColor)
        .frame(width: 9, height: 9)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(
          LocalizedStringKey(
            snapshot.sync.transport == .notConfigured
              ? "sync.not_configured"
              : (snapshot.sync.isFromCache == true ? "sync.cached" : "sync.connected")
          )
        )
        .font(.headline)

        if snapshot.sync.transport != .notConfigured {
          Text(snapshot.sourceDevice.name)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .privacySensitive()
        }
      }

      Spacer(minLength: 12)

      if snapshot.generatedAt != .distantPast {
        VStack(alignment: .trailing, spacing: 3) {
          Text("sync.last_update")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(snapshot.generatedAt, style: .relative)
            .font(.subheadline.weight(.semibold))
        }
      }
    }
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var syncIndicatorColor: Color {
    if snapshot.sync.transport == .notConfigured { return .secondary }
    if snapshot.sync.isFromCache == true { return .orange }
    return .green
  }

  private var summaryGrid: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 145), spacing: 12)],
      alignment: .leading,
      spacing: 12
    ) {
      MetricCard(
        titleKey: "metric.agents",
        value: snapshot.relevantAgents.count.formatted(),
        systemImage: "cpu",
        tint: .blue
      )
      MetricCard(
        titleKey: "metric.running",
        value: snapshot.activeAgents.count.formatted(),
        systemImage: "waveform.path.ecg",
        tint: snapshot.activeAgents.isEmpty ? .secondary : .green
      )
      MetricCard(
        titleKey: "metric.conversations",
        value: snapshot.activeConversationCount.formatted(),
        systemImage: "bubble.left.and.bubble.right",
        tint: .purple
      )
      MetricCard(
        titleKey: "metric.tokens",
        value: DashboardFormatting.tokens(snapshot.usage.total),
        systemImage: "number",
        tint: .mint
      )
    }
  }

  private var agentSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("agents.section.title")
          .font(.title2.bold())
        Spacer()
        if store.isRefreshing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel(Text("sync.refreshing"))
        }
      }

      ForEach(sortedAgents) { agent in
        AgentCard(
          agent: agent,
          revealFullTitles: store.revealFullConversationTitles
        )
      }
    }
  }

  private var sortedAgents: [AgentSummary] {
    snapshot.relevantAgents.sorted { lhs, rhs in
      if lhs.isWorking != rhs.isWorking { return lhs.isWorking }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("empty.title", systemImage: "macbook.and.iphone")
    } description: {
      Text("empty.description")
    } actions: {
      Button("action.refresh") {
        Task { await store.refresh() }
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  @ViewBuilder
  private var liveActivitySection: some View {
    #if os(iOS) && canImport(ActivityKit)
      if #available(iOS 16.2, *) {
        VStack(alignment: .leading, spacing: 10) {
          Label("activity.title", systemImage: "dot.radiowaves.left.and.right")
            .font(.headline)

          Text("activity.description")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          Button {
            Task { await store.toggleLiveActivity() }
          } label: {
            Label {
              Text(
                LocalizedStringKey(
                  store.isLiveActivityRunning ? "activity.stop" : "activity.start"
                ))
            } icon: {
              Image(systemName: store.isLiveActivityRunning ? "stop.circle" : "play.circle")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(snapshot.activeAgents.isEmpty && !store.isLiveActivityRunning)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
    #endif
  }

  private var privacyNote: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text("privacy.sync_note")
      } icon: {
        Image(systemName: "hand.raised.fill")
      }

      HStack(spacing: 18) {
        if let privacyPolicyURL = releaseLinks.privacyPolicyURL {
          Link(destination: privacyPolicyURL) {
            Label("privacy.policy_link", systemImage: "lock.doc")
          }
        }

        if let supportURL = releaseLinks.supportURL {
          Link(destination: supportURL) {
            Label("support.link", systemImage: "questionmark.circle")
          }
        }
      }
      .font(.subheadline.weight(.semibold))

      #if DEBUG
        if releaseLinks.privacyPolicyURL == nil || releaseLinks.supportURL == nil {
          Label("release.links_not_configured", systemImage: "hammer.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
      #endif
    }
    .font(.footnote)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 4)
    .padding(.bottom, 18)
  }

  @ToolbarContentBuilder
  private var privacyToolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      Button(action: store.toggleTitlePrivacy) {
        Label {
          Text(
            LocalizedStringKey(
              store.revealFullConversationTitles ? "privacy.hide_titles" : "privacy.show_titles"
            ))
        } icon: {
          Image(systemName: store.revealFullConversationTitles ? "eye.slash" : "eye")
        }
      }
      .disabled(!store.fullTitlesAvailable)
      .accessibilityHint(
        Text(
          LocalizedStringKey(
            store.fullTitlesAvailable
              ? "privacy.title_toggle_hint"
              : "privacy.titles_unavailable"
          )))
    }
  }

  private func errorBanner(_ message: String) -> some View {
    Label {
      Text(verbatim: message)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
    }
    .font(.subheadline)
    .foregroundStyle(.red)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
  }
}

private struct DashboardReleaseLinks {
  let displayName: String
  let privacyPolicyURL: URL?
  let supportURL: URL?

  init(bundle: Bundle = .main) {
    let configuredName =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.displayName =
      if let configuredName, !configuredName.isEmpty, !configuredName.contains("$(") {
        configuredName
      } else {
        NSLocalizedString("dashboard.title", bundle: bundle, comment: "")
      }
    self.privacyPolicyURL = Self.validHTTPSURL(
      bundle.object(forInfoDictionaryKey: "AgentIslandPrivacyPolicyURL")
    )
    self.supportURL = Self.validHTTPSURL(
      bundle.object(forInfoDictionaryKey: "AgentIslandSupportURL")
    )
  }

  private static func validHTTPSURL(_ rawValue: Any?) -> URL? {
    guard let rawString = rawValue as? String else { return nil }
    let value = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("$("),
      let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.user == nil,
      components.password == nil,
      let host = components.host?.lowercased(),
      !host.isEmpty,
      let url = components.url
    else {
      return nil
    }

    let forbiddenMarkers = ["example.invalid", "placeholder", "yourdomain", "yourname"]
    guard !forbiddenMarkers.contains(where: { host.contains($0) }),
      host != "localhost",
      !host.hasSuffix(".local")
    else {
      return nil
    }
    return url
  }
}

private struct MetricCard: View {
  let titleKey: LocalizedStringKey
  let value: String
  let systemImage: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3.weight(.semibold))
        .foregroundStyle(tint)
        .accessibilityHidden(true)

      Text(value)
        .font(.system(.title2, design: .rounded, weight: .bold))
        .contentTransition(.numericText())
        .minimumScaleFactor(0.75)

      Text(titleKey)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

private struct AgentCard: View {
  let agent: AgentSummary
  let revealFullTitles: Bool

  private var visibleConversations: [ConversationSummary] {
    Array(
      agent.conversations.sorted { lhs, rhs in
        if lhs.isWorking != rhs.isWorking { return lhs.isWorking }
        return lhs.activeDurationSeconds > rhs.activeDurationSeconds
      }.prefix(3))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(stateColor.opacity(0.14))
          Image(systemName: "cpu.fill")
            .font(.title3)
            .foregroundStyle(stateColor)
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text(agent.displayName)
            .font(.headline)
            .lineLimit(1)
          Text(agent.toolName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .privacySensitive()

        Spacer(minLength: 8)
        StateBadge(state: agent.state)
      }

      HStack(spacing: 24) {
        compactMetric(
          labelKey: "metric.duration",
          value: DashboardFormatting.duration(agent.activeDurationSeconds)
        )
        compactMetric(
          labelKey: "metric.tokens",
          value: DashboardFormatting.tokens(agent.usage.total)
        )
      }

      if !visibleConversations.isEmpty {
        Divider()

        VStack(alignment: .leading, spacing: 10) {
          Text("conversations.active")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

          ForEach(Array(visibleConversations.enumerated()), id: \.element.id) {
            index, conversation in
            ConversationRow(
              conversation: conversation,
              index: index,
              revealFullTitle: revealFullTitles
            )
          }

          if agent.conversations.count > visibleConversations.count {
            let remainder = agent.conversations.count - visibleConversations.count
            Text("+\(remainder)")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(16)
    .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(agent.isWorking ? Color.green.opacity(0.35) : Color.clear)
    }
  }

  private func compactMetric(labelKey: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(labelKey)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .semibold))
    }
    .accessibilityElement(children: .combine)
  }

  private var stateColor: Color {
    switch agent.state {
    case .working: return .green
    case .idle: return .orange
    case .completed: return .blue
    case .failed: return .red
    }
  }
}

private struct StateBadge: View {
  let state: AgentState

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(LocalizedStringKey(state.localizationKey))
        .font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(color.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .combine)
  }

  private var color: Color {
    switch state {
    case .working: return .green
    case .idle: return .orange
    case .completed: return .blue
    case .failed: return .red
    }
  }
}

private struct ConversationRow: View {
  let conversation: ConversationSummary
  let index: Int
  let revealFullTitle: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: conversation.isWorking ? "sparkles" : "checkmark.circle")
        .foregroundStyle(conversation.isWorking ? Color.green : Color.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(displayText)
          .font(.subheadline.weight(.medium))
          .lineLimit(2)
          .privacySensitive(revealFullTitle)

        HStack(spacing: 8) {
          Text(DashboardFormatting.duration(conversation.activeDurationSeconds))
          Text("•")
          Text(DashboardFormatting.tokens(conversation.usage.total))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var displayText: String {
    if revealFullTitle,
      let title = conversation.title?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty
    {
      return title
    }

    let summary = conversation.safeSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !summary.isEmpty { return summary }

    let format = NSLocalizedString("conversation.private_number", comment: "")
    return String.localizedStringWithFormat(format, index + 1)
  }
}

#if DEBUG
  #Preview("English") {
    DashboardView(store: DashboardStore(provider: PreviewSnapshotProvider()))
      .environment(\.locale, Locale(identifier: "en"))
  }

  #Preview("简体中文") {
    DashboardView(store: DashboardStore(provider: PreviewSnapshotProvider()))
      .environment(\.locale, Locale(identifier: "zh-Hans"))
  }
#endif
